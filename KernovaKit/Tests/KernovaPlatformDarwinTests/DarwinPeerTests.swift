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

    @Test("A connect the kernel answers inside the deadline completes; one it never answers is abandoned")
    func boundedConnect() {
        let gate = Clock().gate()
        #expect(
            DarwinVsockConnect.boundedBlockingConnect(fd: -1, label: "t", port: 1, gate: gate) { ECONNREFUSED }
                == .failed(errno: ECONNREFUSED))
        let release = DispatchSemaphore(value: 0)
        let waits = OffTaskWaits()
        let pipeEnds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { pipeEnds.deallocate() }
        #expect(pipe(pipeEnds) == 0)
        close(pipeEnds[1])
        // The worker owns the abandoned descriptor and closes it once the call returns.
        #expect(
            DarwinVsockConnect.boundedBlockingConnect(fd: pipeEnds[0], label: "t", port: 1, gate: gate, deadline: 0.05)
            {
                waits.run { try Backstop("the test's release of the connect").wait(for: release) }
                return 0
            } == .abandoned)
        // The abandoned attempt is the one park: the cap is one park short of
        // the rest, and reached with one more.
        for _ in 0..<(BlockingConnectGate.maxParkedAttempts - 2) { gate.markParked("t") }
        #expect(gate.admit("t"))
        gate.markParked("t")
        #expect(gate.admit("t") == false)
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
        #expect(gate.admit("t"))
        // The parks are still outstanding: one discharged and one parked
        // leaves the count where it was, which a new park's rationing reads as
        // at the cap.
        gate.markParkReturned("t")
        gate.markParked("t")
        #expect(gate.admit("t") == false)
    }
}
#endif
