import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

/// What a socket opened just after a channel closed saw at its far end.
private struct ReuseProbe: Sendable {
    /// Whether the probe's host end took the descriptor number the channel
    /// released.
    let reusedNumber: Bool
    /// Bytes the kernel accepted at the probe's agent end.
    let written: Int
    /// `recv(MSG_PEEK)` at the probe's host end, which nothing of the test's
    /// reads: every accepted byte, unless someone else read them.
    let peeked: Int
    let peekErrno: Int32

    var stolen: Int { written - max(0, peeked) }
}

/// Whether a closed `VsockChannel` ever reads the socket the system hands its
/// descriptor number to next.
@Suite("VsockChannel descriptor reuse", .serialized, .caseScoped)
struct VsockChannelDescriptorReuseTests {
    private static let rounds = 200
    private static let framesPerRound = 20

    /// Opens a socketpair, fills it from one end without reading the other, and
    /// reports how much of what the kernel accepted is still buffered.
    private static func probe(releasedNumber: Int32) -> ReuseProbe? {
        let pair: (Int32, Int32)
        do {
            pair = try makeRawSocketPair()
        } catch {
            return nil
        }
        let (agentFd, hostFd) = pair
        defer {
            Darwin.close(agentFd)
            Darwin.close(hostFd)
        }
        var bufferBytes: Int32 = 8192
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(agentFd, SOL_SOCKET, SO_SNDBUF, &bufferBytes, optionSize)
        setsockopt(hostFd, SOL_SOCKET, SO_RCVBUF, &bufferBytes, optionSize)
        var noSigPipe: Int32 = 1
        setsockopt(agentFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, optionSize)
        _ = fcntl(agentFd, F_SETFL, fcntl(agentFd, F_GETFL) | O_NONBLOCK)

        let chunk = [UInt8](repeating: 0x5A, count: 1024)
        var written = 0
        // Rounds apart, so a reader on the host end has time to make room.
        for _ in 0..<5 {
            while true {
                let wrote = chunk.withUnsafeBytes { Darwin.write(agentFd, $0.baseAddress, $0.count) }
                guard wrote > 0 else { break }
                written += wrote
            }
            usleep(2_000)
        }
        var peek = [UInt8](repeating: 0, count: 1 << 20)
        let peeked = peek.withUnsafeMutableBytes {
            recv(hostFd, $0.baseAddress, $0.count, MSG_PEEK | MSG_DONTWAIT)
        }
        let peekErrno = peeked < 0 ? errno : 0
        return ReuseProbe(
            reusedNumber: hostFd == releasedNumber, written: written, peeked: peeked,
            peekErrno: peekErrno)
    }

    private func report(_ outcomes: [ReuseProbe], variant: String) {
        let reused = outcomes.filter(\.reusedNumber).count
        let thefts = outcomes.enumerated().filter { $0.element.stolen > 0 }
        let detail = thefts.map { index, probe in
            "#\(index) reused=\(probe.reusedNumber) written=\(probe.written)"
                + " peeked=\(probe.peeked) errno=\(probe.peekErrno)"
        }
        let summary =
            "\(variant): \(outcomes.count) probes, \(reused) on the released number, \(thefts.count) short: \(detail)"
        print("[descriptor-reuse] \(summary)")
        #expect(thefts.isEmpty, "\(summary)")
    }

    private func exchange(from agent: VsockChannel, to host: VsockChannel) async throws {
        for index in 0..<Self.framesPerRound {
            try agent.send(makeLogFrame(message: "r\(index)"))
        }
        for _ in 0..<Self.framesPerRound {
            _ = try await nextFrame(from: host)
        }
    }

    @Test("A channel its owner closes reads nothing on the socket that reuses its number")
    func ownerClose() async throws {
        var outcomes: [ReuseProbe] = []
        for _ in 0..<Self.rounds {
            let (agentFd, hostFd) = try makeRawSocketPair()
            let agent = VsockChannel(fileDescriptor: agentFd)
            let host = VsockChannel(fileDescriptor: hostFd)
            agent.start()
            host.start()
            try await exchange(from: agent, to: host)
            host.close()
            agent.close()
            if let outcome = await offCooperativePool({ Self.probe(releasedNumber: hostFd) }) {
                outcomes.append(outcome)
            }
        }
        report(outcomes, variant: "owner close")
    }

    @Test("A channel that sees its peer hang up reads nothing on the socket that reuses its number")
    func peerHangUp() async throws {
        var outcomes: [ReuseProbe] = []
        for _ in 0..<Self.rounds {
            let (agentFd, hostFd) = try makeRawSocketPair()
            let agent = VsockChannel(fileDescriptor: agentFd)
            let host = VsockChannel(fileDescriptor: hostFd)
            agent.start()
            host.start()
            try await exchange(from: agent, to: host)
            agent.close()
            _ = try? await nextFrame(from: host)
            host.close()
            if let outcome = await offCooperativePool({ Self.probe(releasedNumber: hostFd) }) {
                outcomes.append(outcome)
            }
        }
        report(outcomes, variant: "peer hang-up")
    }

    @Test("A channel closed mid-burst reads nothing on the socket that reuses its number")
    func closeMidBurst() async throws {
        var outcomes: [ReuseProbe] = []
        for _ in 0..<Self.rounds {
            let (agentFd, hostFd) = try makeRawSocketPair()
            let agent = VsockChannel(fileDescriptor: agentFd)
            let host = VsockChannel(fileDescriptor: hostFd)
            agent.start()
            host.start()
            let sender = Task.detached {
                for index in 0..<200 {
                    try? agent.send(makeLogFrame(message: "burst\(index)"))
                }
            }
            _ = try await nextFrame(from: host)
            host.close()
            await sender.value
            agent.close()
            if let outcome = await offCooperativePool({ Self.probe(releasedNumber: hostFd) }) {
                outcomes.append(outcome)
            }
        }
        report(outcomes, variant: "close mid-burst")
    }

    @Test("Control: a raw descriptor closed by its owner")
    func rawControl() async throws {
        var outcomes: [ReuseProbe] = []
        for _ in 0..<Self.rounds {
            let (agentFd, hostFd) = try makeRawSocketPair()
            let agent = VsockChannel(fileDescriptor: agentFd)
            agent.start()
            for index in 0..<Self.framesPerRound {
                try agent.send(makeLogFrame(message: "r\(index)"))
            }
            Darwin.close(hostFd)
            agent.close()
            if let outcome = await offCooperativePool({ Self.probe(releasedNumber: hostFd) }) {
                outcomes.append(outcome)
            }
        }
        report(outcomes, variant: "raw control")
    }
}
