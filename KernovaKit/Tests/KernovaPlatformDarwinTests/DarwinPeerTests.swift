#if os(macOS)
import Darwin
import Foundation
import KernovaAgentCore
import KernovaSynchronization
import KernovaTestSupport
import Testing

@testable import KernovaPlatformDarwin

@Suite("The macOS peer's identity and session state", .caseScoped)
struct DarwinPeerTests {
    static let executable = "/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent"

    @Test("A slot is read from the executable's path, and only from the slot layout's shape")
    func slots() {
        let root = "/Users/pbear/Library/Application Support/Kernova/Guest Agent"
        let slot = DarwinIdentity.slot(ofExecutable: root + "/slots/b" + Self.executable)
        #expect(slot?.root == root && slot?.slot == "b")
        #expect(DarwinIdentity.slot(ofExecutable: "/Applications" + Self.executable) == nil)
        #expect(DarwinIdentity.slot(ofExecutable: root + "/other/b" + Self.executable) == nil)
        #expect(DarwinIdentity.slot(ofExecutable: root + "/slots/b/KernovaMacOSAgent") == nil)
    }

    @Test("The scope is system at the system root, user at any other root with state.json, else unspecified")
    func scopes() {
        let system = MacInstallLayout.systemRoot
        let user = "/Users/pbear/" + MacInstallLayout.userRootBelowHome
        let installed: Set<String> = [system + "/state.json", user + "/state.json"]
        func scope(_ path: String) -> InstallScope {
            DarwinIdentity.scope(ofExecutable: path, systemRoot: system) { installed.contains($0) }
        }
        #expect(scope(system + "/slots/a" + Self.executable) == .system)
        #expect(scope(user + "/slots/b" + Self.executable) == .user)
        #expect(scope("/tmp/x/slots/a" + Self.executable) == .unspecified)
        #expect(scope("/Applications" + Self.executable) == .unspecified)
    }

    @Test("The system peer reports the console off at the login window, and leaves a user's console unknown")
    func systemPeerState() {
        #expect(DarwinSessionState.systemPeer(consoleUser: nil) == PeerSessionState(console: .off))
        #expect(DarwinSessionState.systemPeer(consoleUser: "loginwindow") == PeerSessionState(console: .off))
        #expect(DarwinSessionState.systemPeer(consoleUser: "pbear") == PeerSessionState(console: .unknown))
    }

    @Test(
        "The GUI login sessions are the console line's user processes: Fast User Switching's background sessions among them, terminal logins and dead records not"
    )
    func guiLoginUsers() {
        typealias Record = DarwinSessionState.LoginRecord
        let records = [
            Record(type: Int16(BOOT_TIME), line: "~", user: ""),
            Record(type: Int16(USER_PROCESS), line: "console", user: "pbear"),
            Record(type: Int16(USER_PROCESS), line: "ttys000", user: "pbear"),
            Record(type: Int16(USER_PROCESS), line: "console", user: "tester"),
            Record(type: Int16(DEAD_PROCESS), line: "console", user: "gone"),
        ]
        #expect(DarwinSessionState.guiLoginUsers(in: records) == ["pbear", "tester"])
        #expect(DarwinSessionState.guiLoginUsers(in: Array(records.prefix(1) + records[2...2])).isEmpty)
    }

    @Test("The session peer reports its own audit session")
    func sessionPeerState() {
        let state = DarwinSessionState.sessionPeer()
        #expect(state.sessionID == DarwinSessionState.auditSessionID.map(String.init))
        #expect(!state.sessionID.isEmpty && !state.userName.isEmpty)
    }

    @Test("The watcher reports once a slot link points away from the running slot, and only once")
    func slotLinkWatcher() throws {
        let root = TestScratchDirectory(prefix: "kernova-link").url.path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/current", withDestinationPath: "slots/a")
        let moved = DispatchSemaphore(value: 0)
        let count = Locked(0)
        let changes = Locked<[SlotLinkWatcher.Change]>([])
        let queue = DispatchQueue(label: "test.watcher")
        let watcher = try #require(
            SlotLinkWatcher(root: root, runningSlot: "a", queue: queue) { change in
                count.withLock { $0 += 1 }
                changes.withLock { $0.append(change) }
                moved.signal()
            })
        defer { watcher.cancel() }
        // Settled once the watcher has checked the link it started with.
        queue.sync {}
        #expect(count.withLock { $0 } == 0)
        try FileManager.default.createSymbolicLink(atPath: root + "/current.new", withDestinationPath: "slots/b")
        #expect(rename(root + "/current.new", root + "/current") == 0)
        moved.wait()
        try FileManager.default.createSymbolicLink(atPath: root + "/current.new", withDestinationPath: "slots/a")
        #expect(rename(root + "/current.new", root + "/current") == 0)
        queue.sync {}
        #expect(count.withLock { $0 } == 1)
        #expect(changes.withLock { $0 } == [.moved])
    }

    @Test("The watcher reports the link's removal — an uninstall — apart from a move, so the peer stops for good")
    func slotLinkWatcherRemoval() throws {
        let root = TestScratchDirectory(prefix: "kernova-link").url.path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/current", withDestinationPath: "slots/a")
        let changed = DispatchSemaphore(value: 0)
        let changes = Locked<[SlotLinkWatcher.Change]>([])
        let queue = DispatchQueue(label: "test.watcher")
        let watcher = try #require(
            SlotLinkWatcher(root: root, runningSlot: "a", queue: queue) { change in
                changes.withLock { $0.append(change) }
                changed.signal()
            })
        defer { watcher.cancel() }
        queue.sync {}
        #expect(changes.withLock { $0 }.isEmpty)
        #expect(unlink(root + "/current") == 0)
        changed.wait()
        #expect(changes.withLock { $0 } == [.removed])
    }
}

@Suite("The bounded blocking connect: socket ownership and the parked-attempt gate", .caseScoped)
struct BlockingConnectTests {
    /// A clock the test advances by hand.
    final class Clock: Sendable {
        private let instant = Locked(CoreInstant(nanoseconds: 1_000_000_000))
        var now: CoreInstant { instant.withLock { $0 } }
        func advance(seconds: TimeInterval) {
            instant.withLock { $0 = $0.advanced(by: CoreDuration(nanoseconds: Int64(seconds * 1_000_000_000))) }
        }
        func gate() -> BlockingConnectGate { BlockingConnectGate { [self] in now } }
    }

    @Test("A syscall that beats the deadline hands the socket to the waiter")
    func syscallBeatsDeadline() {
        let handoff = BlockingConnectHandoff()
        #expect(handoff.finish(errno: 0))
        #expect(handoff.abandon() == false)
        #expect(handoff.outcome == 0)
    }

    @Test("A syscall that outruns the deadline keeps the socket")
    func syscallOutrunsDeadline() {
        let handoff = BlockingConnectHandoff()
        #expect(handoff.abandon())
        #expect(handoff.outcome == nil)
        #expect(handoff.finish(errno: ECONNREFUSED) == false)
        #expect(handoff.outcome == ECONNREFUSED)
    }

    @Test("Attempts that never park are admitted however many run in a row")
    func gateAdmitsEveryHealthyAttempt() {
        let gate = Clock().gate()
        for _ in 0..<(BlockingConnectGate.maxParkedAttempts * 8) { #expect(gate.admit("data")) }
        #expect(gate.parkedCount("data") == 0)
    }

    @Test("Past the parked cap, admission waits out a doubling backoff")
    func gateBacksOffPastParkedCap() {
        let clock = Clock()
        let gate = clock.gate()
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        #expect(gate.admit("control") == false)
        clock.advance(seconds: BlockingConnectGate.backoffFloor - 1)
        #expect(gate.admit("control") == false)
        clock.advance(seconds: 1)
        #expect(gate.admit("control"))
        gate.markParked("control")
        // One attempt past the cap doubles the wait.
        clock.advance(seconds: BlockingConnectGate.backoffFloor)
        #expect(gate.admit("control") == false)
        clock.advance(seconds: BlockingConnectGate.backoffFloor)
        #expect(gate.admit("control"))
    }

    @Test("The backoff never exceeds its ceiling however many attempts are parked")
    func gateBackoffStopsAtCeiling() {
        let clock = Clock()
        let gate = clock.gate()
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        var backoff = BlockingConnectGate.backoffFloor
        while backoff < BlockingConnectGate.backoffCeiling {
            #expect(gate.admit("control") == false)
            clock.advance(seconds: backoff)
            #expect(gate.admit("control"))
            gate.markParked("control")
            backoff *= 2
        }
        for _ in 0..<2 {
            clock.advance(seconds: BlockingConnectGate.backoffCeiling - 1)
            #expect(gate.admit("control") == false)
            clock.advance(seconds: 1)
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
    }

    @Test("An attempt completing inside its deadline lifts the rationing")
    func gateHealsOnACompletedAttempt() {
        let gate = Clock().gate()
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        #expect(gate.admit("control") == false)
        gate.markCompleted("control")
        #expect(gate.admit("control"))
        #expect(gate.admit("control"))
        #expect(gate.parkedCount("control") == BlockingConnectGate.maxParkedAttempts)
    }

    @Test("A park after a heal is rationed from the floor, not the escalated wait")
    func gateRationsAgainFromTheFloorAfterAHeal() {
        let clock = Clock()
        let gate = clock.gate()
        for _ in 0..<(BlockingConnectGate.maxParkedAttempts + 8) { gate.markParked("control") }
        gate.markCompleted("control")
        #expect(gate.admit("control"))
        gate.markParked("control")
        #expect(gate.admit("control") == false)
        clock.advance(seconds: BlockingConnectGate.backoffFloor - 1)
        #expect(gate.admit("control") == false)
        clock.advance(seconds: 1)
        #expect(gate.admit("control"))
    }

    @Test("A parked syscall returning discharges its attempt, and returned parks never escalate the next wedge")
    func gateDischargesReturnedParks() {
        let clock = Clock()
        let gate = clock.gate()
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        #expect(gate.admit("control") == false)
        gate.markParkReturned("control")
        #expect(gate.parkedCount("control") == BlockingConnectGate.maxParkedAttempts - 1)
        #expect(gate.admit("control"))

        let other = clock.gate()
        for _ in 0..<(BlockingConnectGate.maxParkedAttempts + 8) { other.markParked("c") }
        for _ in 0..<(BlockingConnectGate.maxParkedAttempts + 8) { other.markParkReturned("c") }
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(other.admit("c"))
            other.markParked("c")
        }
        #expect(other.admit("c") == false)
        clock.advance(seconds: BlockingConnectGate.backoffFloor)
        #expect(other.admit("c"))
    }

    @Test("A park reverted because the syscall beat the deadline leaves the count unchanged")
    func gateRevertedParkLeavesTheCountUnchanged() {
        let gate = Clock().gate()
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        gate.markParked("control")
        gate.revertPark("control")
        #expect(gate.parkedCount("control") == BlockingConnectGate.maxParkedAttempts)
        #expect(gate.admit("control"))
    }

    @Test("A connect the kernel answers inside the deadline completes; one it never answers is abandoned")
    func boundedConnect() {
        let gate = Clock().gate()
        #expect(
            DarwinVsockConnect.boundedBlockingConnect(fd: -1, label: "t", port: 1, gate: gate) { ECONNREFUSED }
                == .failed(errno: ECONNREFUSED))
        let release = DispatchSemaphore(value: 0)
        let pipeEnds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { pipeEnds.deallocate() }
        #expect(pipe(pipeEnds) == 0)
        close(pipeEnds[1])
        // The worker owns the abandoned descriptor and closes it once the call returns.
        #expect(
            DarwinVsockConnect.boundedBlockingConnect(fd: pipeEnds[0], label: "t", port: 1, gate: gate, deadline: 0.05)
            {
                release.wait()
                return 0
            } == .abandoned)
        #expect(gate.parkedCount("t") == 1)
        release.signal()
    }

    @Test("A gate refusal reports busy without running the connect; a completed attempt lifts the backoff")
    func gateRefusalAndHeal() {
        let clock = Clock()
        let gate = clock.gate()
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("t"))
            gate.markParked("t")
        }
        let calls = Locked(0)
        #expect(
            DarwinVsockConnect.boundedBlockingConnect(fd: -1, label: "t", port: 1, gate: gate) {
                calls.withLock { $0 += 1 }
                return 0
            } == .busy)
        #expect(calls.withLock { $0 } == 0)
        clock.advance(seconds: BlockingConnectGate.backoffFloor)
        // A refusal inside the deadline proves the host answers, so the next attempt waits out no backoff even
        // with the parks still outstanding.
        #expect(
            DarwinVsockConnect.boundedBlockingConnect(fd: -1, label: "t", port: 1, gate: gate) { ECONNREFUSED }
                == .failed(errno: ECONNREFUSED))
        #expect(gate.parkedCount("t") == BlockingConnectGate.maxParkedAttempts)
        #expect(gate.admit("t"))
    }

    @Test("POLLHUP with SO_ERROR 0 completes a non-blocking connect; POLLNVAL stays fatal")
    func connectCompletion() throws {
        guard #available(macOS 26.0, *) else { return }
        // A socketpair end whose peer has closed reports POLLHUP while SO_ERROR reads 0, the shape a connect the
        // host accepted and then hung up on takes.
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        close(fds[1])
        defer { close(fds[0]) }
        #expect(DarwinVsockConnect.awaitConnectCompletion(fd: fds[0], label: "t", port: 0))
        // A number at the fd-table size never names an open descriptor, so poll() reports POLLNVAL.
        #expect(!DarwinVsockConnect.awaitConnectCompletion(fd: getdtablesize(), label: "t", port: 0))
    }

    @Test("EAFNOSUPPORT and EPROTONOSUPPORT are permanent; anything else is transient")
    func classification() {
        for code in [EAFNOSUPPORT, EPROTONOSUPPORT] {
            guard case .permanent = DarwinVsockConnect.classifySocketErrno(code, label: "t") else {
                Issue.record("\(code) is not permanent")
                continue
            }
        }
        for code in [EMFILE, 0] {
            guard case .transient = DarwinVsockConnect.classifySocketErrno(code, label: "t") else {
                Issue.record("\(code) is not transient")
                continue
            }
        }
    }
}
#endif
