import KernovaLogging
import Testing
import Foundation
import Darwin
import KernovaKit
import KernovaTestSupport

// Substrings identifying the drain worker's own records; production owns the
// wording, these pick the line out of a ring or a recorder.
private let bufferFullMarker = "Log forward buffer full"
private let sendFailedMarker = "Log channel send failed"
private let droppedCountMarker = "buffered log record(s) while the host channel was behind"

/// Captures `VsockHostConnection`'s own log records for the length of one test,
/// and optionally feeds them back through `forwardLog` the way
/// `AgentAppDelegate` wires the real sink.
///
/// `KernovaLogger.forwardingSink` is process-wide, so the sink is narrowed to
/// the one category under test and the suite runs `.serialized`. `changed`
/// fires after each record has been forwarded, which is the drain worker's only
/// signal — it reports its outcome by logging and nothing else.
private final class AgentLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    let changed = AsyncGate()

    private let forwardTarget: VsockHostConnection?

    init(forwardingTo conn: VsockHostConnection? = nil) {
        self.forwardTarget = conn
    }

    var messages: [String] { lock.withLock { recorded } }

    func count(matching marker: String) -> Int {
        messages.filter { $0.contains(marker) }.count
    }

    func install() {
        KernovaLogger.forwardingSink = { [self] level, subsystem, category, segments in
            guard category == "VsockHostConnection" else { return }
            lock.withLock { recorded.append(segments.map(\.text).joined()) }
            forwardTarget?.forwardLog(
                level: level, subsystem: subsystem, category: category, segments: segments)
            changed.notify()
        }
    }

    func uninstall() {
        KernovaLogger.forwardingSink = nil
    }
}

/// Tests that seed the ring directly call `bufferFrameUnlessDisabled` on a
/// fresh connection, whose policy is `.undecided` — the state that buffers, so
/// they run through the in-lock policy re-check on its appending branch.
///
/// Serialized because `KernovaLogger.forwardingSink` is process-wide: a second
/// `VsockHostConnection` running concurrently would emit into whichever ring
/// the installed sink points at.
@Suite("VsockHostConnection log buffer", .serialized, .admissionGated)
struct VsockHostConnectionTests {
    // MARK: - Buffer helpers

    private func pendingLogCount(_ conn: VsockHostConnection) -> Int {
        conn.lock.withLock { conn.pendingLogs.count }
    }

    private func pendingMessages(_ conn: VsockHostConnection) -> [String] {
        conn.lock.withLock {
            conn.pendingLogs.compactMap { frame -> String? in
                guard case .logRecord(let record) = frame.payload else { return nil }
                return record.segments.map(\.text).joined()
            }
        }
    }

    // MARK: - Dialled-connection fixture

    /// A connection whose client dials socketpairs the test owns the far ends
    /// of, one per connect attempt.
    private struct DialledConnection {
        let conn: VsockHostConnection
        let client: VsockGuestClient
        /// Host ends, in attempt order — raw, so a test can starve one by never
        /// reading it or wrap it in a `VsockChannel` to receive.
        let hostFds: [Int32]
        /// Connect attempts the client has made.
        let dialled: AtomicInt
    }

    /// Builds a connection dialling `attempts` socketpairs.
    ///
    /// The retry interval is far past `testWaitBackstop`, so a second connect
    /// can only land inside a test because a policy update woke the loop.
    /// `socketBufferBytes` shrinks both ends' buffers, which is what lets a
    /// handful of frames fill the socket and park the drain worker in
    /// `write(2)`.
    private func makeDialledConnection(
        label: String, attempts: Int = 1, socketBufferBytes: Int32? = nil
    ) throws -> DialledConnection {
        var pairs: [(agent: Int32, host: Int32)] = []
        for _ in 0..<attempts {
            let (agentFd, hostFd) = try makeRawSocketPair()
            if var size = socketBufferBytes {
                let optionSize = socklen_t(MemoryLayout<Int32>.size)
                setsockopt(agentFd, SOL_SOCKET, SO_SNDBUF, &size, optionSize)
                setsockopt(hostFd, SOL_SOCKET, SO_RCVBUF, &size, optionSize)
            }
            pairs.append((agent: agentFd, host: hostFd))
        }
        let agentFds = pairs.map(\.agent)

        let dialled = AtomicInt()
        let client = VsockGuestClient(
            port: KernovaVsockPort.log,
            label: label,
            clock: MonotonicEngineClock(),
            retryInterval: 600
        ) { _, _ in
            let n = dialled.increment()
            guard n <= agentFds.count else { return .failure(.transient("test: no fd for attempt \(n)")) }
            return .success(agentFds[n - 1])
        }
        return DialledConnection(
            conn: VsockHostConnection(client: client), client: client,
            hostFds: pairs.map(\.host), dialled: dialled)
    }

    /// Runs `body` against a connection dialling `attempts` socketpairs, and
    /// returns only once that connection's loop task has exited, whatever
    /// `body` did. The channel-end record is logged from that task, and one
    /// landing after the return reaches the next test's sink instead: counted
    /// there, or forwarded into that test's ring as one more frame.
    private func withDialledConnection(
        label: String, attempts: Int = 1, socketBufferBytes: Int32? = nil,
        _ body: (DialledConnection) async throws -> Void
    ) async throws {
        let dialled = try makeDialledConnection(
            label: label, attempts: attempts, socketBufferBytes: socketBufferBytes)
        var failure: (any Error)?
        do {
            try await body(dialled)
        } catch {
            failure = error
        }
        let loop = dialled.conn.stop()
        await loop?.value
        if let failure { throw failure }
    }

    /// Reads one byte off a host end nothing else reads: it returns as soon as
    /// the agent writes, proving the connect landed and the worker is in the
    /// socket rather than in `forwardLog`.
    ///
    /// The socket's own receive timeout is the backstop, so a channel that
    /// never comes up fails the read instead of hanging the case.
    private func firstByteWritten(to fd: Int32) async -> Int {
        var timeout = timeval(tv_sec: Int(testWaitBackstop), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return await offCooperativePool {
            var byte: UInt8 = 0
            return read(fd, &byte, 1)
        }
    }

    // MARK: - Buffer: basic enqueue

    @Test("forwardLog buffers frames when no live channel is present")
    func buffersWhenNoChannel() {
        let conn = VsockHostConnection()
        conn.setEnabled(true)  // production agents are default-disabled until host policy enables them

        for i in 0..<5 {
            conn.forwardLog(level: .info, subsystem: "test", category: "test", message: "msg\(i)")
        }

        #expect(pendingLogCount(conn) == 5)
    }

    @Test("buffered frames are in FIFO order")
    func bufferedFramesInFIFOOrder() {
        let conn = VsockHostConnection()
        conn.setEnabled(true)

        for i in 0..<3 {
            conn.forwardLog(level: .info, subsystem: "test", category: "test", message: "msg\(i)")
        }

        #expect(pendingMessages(conn) == ["msg0", "msg1", "msg2"])
    }

    // MARK: - Buffer cap

    @Test("buffer drops oldest frames when over cap")
    func bufferDropsOldestOverCap() {
        let conn = VsockHostConnection()
        let total = 300
        let cap = VsockHostConnection.logBufferLimit

        for i in 0..<total {
            conn.bufferFrameUnlessDisabled(makeLogFrame(message: "frame\(i)"))
        }

        #expect(pendingLogCount(conn) == cap)
        // Oldest surviving frame is at index (total - cap) = 44
        #expect(pendingMessages(conn).first == "frame\(total - cap)")
    }

    @Test("buffer cap is exactly logBufferLimit")
    func bufferCapIsExact() {
        let conn = VsockHostConnection()
        let cap = VsockHostConnection.logBufferLimit

        for i in 0..<(cap + 10) {
            conn.bufferFrameUnlessDisabled(makeLogFrame(message: "f\(i)"))
        }

        #expect(pendingLogCount(conn) == cap)
    }

    // MARK: - Drain: healthy channel

    @Test("Records forwarded on a live channel reach the host in order")
    func liveChannelDeliversInOrder() async throws {
        try await withDialledConnection(label: "log-in-order-test") { dialled in
            let conn = dialled.conn
            let host = VsockChannel(fileDescriptor: dialled.hostFds[0])
            host.start()
            defer { host.close() }

            conn.start()
            conn.setEnabled(true)

            let frameCount = 10
            for i in 0..<frameCount {
                conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "drain\(i)")
            }

            var received: [String] = []
            for _ in 0..<frameCount { received.append(try await message(from: host)) }

            #expect(received == (0..<frameCount).map { "drain\($0)" })
            // The worker takes each frame out of the ring before sending it, so
            // the last arrival means the ring is already empty.
            #expect(pendingLogCount(conn) == 0)
        }
    }

    // MARK: - Drain: a stalled host never reaches the caller

    @Test("forwardLog returns while the host has stopped reading the log channel")
    func forwardLogReturnsWhileHostStalls() async throws {
        try await withDialledConnection(label: "log-stalled-host-test", socketBufferBytes: 8192) { dialled in
            let conn = dialled.conn
            // The host end is never wrapped in a channel and never read, so the
            // socket fills and the worker parks in `write(2)` for good.
            let hostFd = dialled.hostFds[0]

            let sink = AgentLogSink()
            sink.install()
            defer { sink.uninstall() }

            conn.start()
            conn.setEnabled(true)

            // One record larger than the socket can hold: its write cannot
            // finish, so the first byte to arrive proves the worker is parked in
            // `write(2)` carrying it, and nothing else leaves the ring while it
            // is.
            let payload = String(repeating: "x", count: 64 * 1024)
            conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "stall-\(payload)")
            #expect(await firstByteWritten(to: hostFd) == 1)
            #expect(pendingLogCount(conn) == 0)

            let cap = VsockHostConnection.logBufferLimit
            for i in 0..<(cap + 50) {
                conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "queued\(i)")
            }
            #expect(pendingLogCount(conn) == cap)

            // The call under test: with the worker parked in the socket,
            // forwarding is still nothing but an append.
            let returned = AtomicInt()
            Task {
                await offCooperativePool {
                    conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "unblocked")
                }
                returned.increment()
            }
            try await returned.changed.wait { returned.value == 1 }
            #expect(pendingLogCount(conn) == cap)

            // Closing the host end wakes the parked write with EPIPE, putting
            // the frame it was carrying back into a ring already at the cap.
            // The count the warning carries is the ring as the worker saw it
            // under the lock that re-inserted the frame; from then on the ring
            // is the drain's again.
            Darwin.close(hostFd)
            try await sink.changed.wait { sink.count(matching: sendFailedMarker) == 1 }
            #expect(sink.count(matching: "holding \(cap) record(s)") == 1)
        }
    }

    // MARK: - Overflow accounting

    @Test("A full buffer announces dropping once, and reports the count once it drains")
    func overflowAnnouncesOnceAndReportsCount() async throws {
        try await withDialledConnection(label: "log-overflow-test") { dialled in
            let conn = dialled.conn
            let host = VsockChannel(fileDescriptor: dialled.hostFds[0])
            host.start()
            defer { host.close() }

            // Enabled before the sink is installed, so its policy notice is not
            // one of the records under count.
            conn.setEnabled(true)
            let sink = AgentLogSink(forwardingTo: conn)
            sink.install()
            defer { sink.uninstall() }

            let cap = VsockHostConnection.logBufferLimit
            let extra = 10
            for i in 0..<(cap + extra) {
                conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "f\(i)")
            }

            // The announcement is itself a forwarded record, so it takes a slot
            // of its own and one more frame is evicted to make room for it.
            let evicted = extra + 1
            let buffered = pendingMessages(conn)
            #expect(buffered.count == cap)
            #expect(buffered.first == "f\(evicted)")
            #expect(buffered.last == "f\(cap + extra - 1)")
            #expect(buffered.filter { $0.contains(bufferFullMarker) }.count == 1)

            // Connecting drains the ring, and the count lands behind everything
            // that survived.
            conn.start()
            var received: [String] = []
            for _ in 0..<(cap + 1) { received.append(try await message(from: host)) }

            #expect(received.first == "f\(evicted)")
            #expect(received.filter { $0.contains(bufferFullMarker) }.count == 1)
            #expect(received.last?.contains("\(evicted) \(droppedCountMarker)") == true)
            #expect(pendingLogCount(conn) == 0)
        }
    }

    // MARK: - Re-entrancy through the process-wide sink

    /// The conversion of this class to `KernovaLogger` turns its own warnings
    /// into `forwardLog` calls that re-enter it, so the drain has to log with
    /// its lock released and without scheduling itself again.
    @Test("A drain's send-failure warning re-enters forwardLog exactly once")
    func sendFailureWarningReentersForwardLogOnce() async throws {
        try await withDialledConnection(label: "log-reentrancy-test", socketBufferBytes: 8192) { dialled in
            let conn = dialled.conn
            let hostFd = dialled.hostFds[0]

            conn.start()
            conn.setEnabled(true)

            // Mirrors `AgentAppDelegate`: every record this class emits is
            // forwarded straight back into the connection emitting it.
            let sink = AgentLogSink(forwardingTo: conn)
            sink.install()
            defer { sink.uninstall() }

            let payload = String(repeating: "x", count: 4096)
            for i in 0..<40 {
                conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "re\(i)-\(payload)")
            }
            #expect(await firstByteWritten(to: hostFd) == 1)

            Darwin.close(hostFd)

            // The sink records the warning and only then forwards it, so the
            // ring — the state the assertions below read — is what this waits
            // on; the sink's own tally is true one step earlier.
            try await sink.changed.wait {
                pendingMessages(conn).contains { $0.contains(sendFailedMarker) }
            }
            // One warning for the outage, whatever else the agent logs into the
            // broken channel afterwards — and it reached the ring, so the
            // forward ran to completion rather than deadlocking on the drain's
            // own lock.
            #expect(sink.count(matching: sendFailedMarker) == 1)
            #expect(pendingMessages(conn).filter { $0.contains(sendFailedMarker) }.count == 1)
            #expect(pendingLogCount(conn) <= VsockHostConnection.logBufferLimit)
        }
    }

    // MARK: - Chronological order across a failed send

    @Test("Chronological order survives a mid-drain send failure and the next connection")
    func orderSurvivesSendFailureAndReconnect() async throws {
        try await withDialledConnection(
            label: "log-order-across-reconnect-test", attempts: 2, socketBufferBytes: 8192
        ) { dialled in
            let conn = dialled.conn

            conn.start()
            conn.setEnabled(true)

            let total = 40
            let payload = String(repeating: "x", count: 4096)
            for i in 0..<total {
                conn.forwardLog(
                    level: .info, subsystem: "t", category: "t",
                    message: String(format: "o%02d-", i) + payload)
            }
            #expect(await firstByteWritten(to: dialled.hostFds[0]) == 1)

            // Fails the in-flight send: the frame it was carrying goes back to
            // the head of the ring, ahead of everything still queued behind it.
            Darwin.close(dialled.hostFds[0])

            let host = VsockChannel(fileDescriptor: dialled.hostFds[1])
            host.start()
            defer { host.close() }
            // The restated enable is the only wake the parked loop gets.
            conn.setEnabled(true)

            var received: [String] = []
            while received.last != String(format: "o%02d", total - 1) {
                received.append(String(try await message(from: host).prefix(3)))
            }

            #expect(dialled.dialled.value == 2)
            // Only what the stalled socket had already swallowed is missing:
            // what arrives is the unbroken tail of the sequence, in order.
            let indices = received.compactMap { Int($0.dropFirst()) }
            #expect(indices.count == received.count)
            #expect(indices == Array(indices[0]..<total))
            #expect(indices.count >= 10)
        }
    }

    // MARK: - Policy enforcement

    @Test("Explicitly disabled: forwardLog drops the frame and skips the buffer")
    func explicitlyDisabledDropsForwardLog() {
        let conn = VsockHostConnection()
        conn.setEnabled(false)  // explicit host "off" — drop, don't buffer

        conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "msg")
        #expect(pendingLogCount(conn) == 0)
        #expect(conn.isLogForwardingEnabled == false)
    }

    @Test("Explicitly disabled: bufferFrameUnlessDisabled drops the frame")
    func explicitlyDisabledDropsBufferedFrame() {
        let conn = VsockHostConnection()
        conn.setEnabled(false)

        conn.bufferFrameUnlessDisabled(makeLogFrame(message: "dropped"))

        #expect(pendingLogCount(conn) == 0)
    }

    /// The failed send's frame reaches `holdForNextConnection` after
    /// `setEnabled(false)` has already cleared the ring — the pause that
    /// disabling performs is what fails the send.
    @Test("Explicitly disabled: a frame parked by a failed send is dropped, and a later enable does not deliver it")
    func explicitlyDisabledDropsParkedFrame() throws {
        let conn = VsockHostConnection()
        conn.setEnabled(false)

        let sink = AgentLogSink()
        sink.install()
        defer { sink.uninstall() }

        conn.holdForNextConnection(
            makeLogFrame(message: "parked"), failedOn: try makeClosedChannel(),
            failure: VsockChannelError.closed)

        #expect(pendingLogCount(conn) == 0)
        #expect(sink.count(matching: sendFailedMarker) == 0)

        conn.setEnabled(true)
        #expect(pendingLogCount(conn) == 0)
    }

    @Test("Enabled: a frame parked by a failed send goes back to the head of the buffer")
    func enabledParksFrameAtHead() throws {
        let conn = VsockHostConnection()
        conn.setEnabled(true)
        conn.bufferFrameUnlessDisabled(makeLogFrame(message: "queued"))

        let sink = AgentLogSink()
        sink.install()
        defer { sink.uninstall() }

        conn.holdForNextConnection(
            makeLogFrame(message: "parked"), failedOn: try makeClosedChannel(),
            failure: VsockChannelError.closed)

        #expect(pendingMessages(conn) == ["parked", "queued"])
        #expect(sink.count(matching: "\(sendFailedMarker), holding 2 record(s)") == 1)
    }

    // MARK: - Undecided policy: pre-handshake buffering (#598)

    @Test("Undecided (no policy yet): forwardLog buffers the frame instead of dropping it")
    func undecidedBuffersForwardLog() {
        let conn = VsockHostConnection()
        // No setEnabled — policy is undecided until the host's first PolicyUpdate.
        #expect(conn.isLogForwardingEnabled == false)

        conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "boot")
        #expect(pendingLogCount(conn) == 1)
    }

    @Test("Undecided-era frames are delivered once forwarding is enabled and the channel connects")
    func undecidedFramesFlushedOnEnableAndConnect() async throws {
        try await withDialledConnection(label: "log-undecided-test") { dialled in
            let conn = dialled.conn
            let host = VsockChannel(fileDescriptor: dialled.hostFds[0])
            host.start()
            defer { host.close() }

            for i in 0..<3 {
                conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "boot\(i)")
            }
            #expect(pendingMessages(conn) == ["boot0", "boot1", "boot2"])

            // The host's first PolicyUpdate enables forwarding; the connect that
            // follows delivers what the undecided window buffered.
            conn.start()
            conn.setEnabled(true)

            var received: [String] = []
            for _ in 0..<3 { received.append(try await message(from: host)) }
            #expect(received == ["boot0", "boot1", "boot2"])
            #expect(pendingLogCount(conn) == 0)
        }
    }

    @Test("A first setEnabled(false) discards undecided-era frames; a later enable does not deliver them")
    func undecidedFramesDiscardedByFirstDisable() {
        let conn = VsockHostConnection()

        for i in 0..<5 {
            conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "boot\(i)")
        }
        #expect(pendingLogCount(conn) == 5)

        // First policy decision is "off": undecided → disabled is a transition, so
        // the buffered undecided-era records are cleared — an explicit "off" ships
        // nothing retroactively.
        conn.setEnabled(false)
        #expect(pendingLogCount(conn) == 0)

        // A later enable must not resurrect them.
        conn.setEnabled(true)
        #expect(pendingLogCount(conn) == 0)
    }

    @Test("setEnabled(true) allows forwardLog to buffer when no channel exists")
    func enabledAllowsBuffering() {
        let conn = VsockHostConnection()
        conn.setEnabled(true)

        conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "msg")
        #expect(pendingLogCount(conn) == 1)
        #expect(conn.isLogForwardingEnabled == true)
    }

    @Test("setEnabled(false) discards the buffered frames")
    func disablingClearsBuffer() {
        let conn = VsockHostConnection()
        conn.setEnabled(true)

        for i in 0..<10 {
            conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "msg\(i)")
        }
        #expect(pendingLogCount(conn) == 10)

        conn.setEnabled(false)
        #expect(pendingLogCount(conn) == 0)
        #expect(conn.isLogForwardingEnabled == false)
    }

    @Test("A repeated setEnabled leaves the policy and the buffer alone")
    func setEnabledIsIdempotent() {
        let conn = VsockHostConnection()

        conn.setEnabled(false)
        conn.setEnabled(false)
        #expect(conn.isLogForwardingEnabled == false)

        conn.setEnabled(true)
        conn.setEnabled(true)
        #expect(conn.isLogForwardingEnabled == true)

        // Buffering still works after a repeat enable.
        conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "x")
        #expect(pendingLogCount(conn) == 1)
    }

    // MARK: - Reconnect

    /// The restated enable is the only wake the parked loop gets.
    ///
    /// The resume-from-saved-state ordering: the log channel redials while the
    /// host's control handshake is still in flight, the host refuses it, and the
    /// policy update that follows the handshake restates the enable the agent
    /// already applied.
    @Test("A policy update restating 'enabled' reconnects and flushes what was buffered")
    func restatedEnablePolicyReconnects() async throws {
        try await withDialledConnection(label: "log-restated-policy-test", attempts: 2) { dialled in
            let conn = dialled.conn
            let host0 = VsockChannel(fileDescriptor: dialled.hostFds[0])
            let host1 = VsockChannel(fileDescriptor: dialled.hostFds[1])
            host0.start()
            host1.start()
            defer { host0.close(); host1.close() }

            conn.start()
            conn.setEnabled(true)
            // The record's arrival is the signal that the first channel is up.
            conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "first")
            #expect(try await message(from: host0) == "first")

            // The host hangs up, as a refused feature channel does; the record
            // written while the loop is parked has nowhere to go but the buffer.
            host0.close()
            // No-signal poll — `liveChannel` is lock-protected client state with
            // no signal to await.
            try await waitUntil { dialled.client.liveChannelForTesting == nil }
            conn.forwardLog(level: .info, subsystem: "t", category: "t", message: "buffered")

            // Same policy, second delivery — the enable the agent already
            // applied.
            conn.setEnabled(true)
            #expect(try await message(from: host1) == "buffered")
            #expect(dialled.dialled.value == 2)
        }
    }

    /// A channel whose send has already failed, standing in for the one a
    /// drain was sending on.
    private func makeClosedChannel() throws -> VsockChannel {
        let (agentFd, hostFd) = try makeRawSocketPair()
        Darwin.close(hostFd)
        let channel = VsockChannel(fileDescriptor: agentFd)
        channel.close()
        return channel
    }

    /// The message of the next `LogRecord` frame on `channel`.
    private func message(from channel: VsockChannel) async throws -> String {
        let frame = try await nextFrame(from: channel)
        guard case .logRecord(let record) = frame.payload else {
            throw TestFailure("Expected a LogRecord frame, got \(String(describing: frame.payload))")
        }
        return record.segments.map(\.text).joined()
    }
}

extension VsockHostConnection {
    /// Forwards a one-segment record — the shape these buffering tests need,
    /// and what a message with no interpolation expands to.
    fileprivate func forwardLog(
        level: KernovaLogLevel, subsystem: String, category: String, message: String
    ) {
        forwardLog(
            level: level, subsystem: subsystem, category: category,
            segments: [LogSegment(text: message, isPrivate: false)])
    }
}
