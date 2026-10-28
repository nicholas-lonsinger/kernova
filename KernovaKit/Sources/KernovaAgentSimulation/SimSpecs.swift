#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// One scripted report of a fake power adapter after `perform`.
package enum PowerReport: Sendable, Equatable {
    case accepted
    case refused(ErrorCode)
    case askingApps
    case waitingOnApps([AppValue])
    case handedOff
    case blocked([AppValue])
    case cancelledInGuest
    case failed(ErrorCode)
}

/// How a fake power adapter answers `cancel`.
package enum CancelBehavior: Sendable, Equatable {
    /// The OS confirms nothing started, after a delay drawn from the window.
    case confirm(after: SimWindow)
    /// The OS confirms nothing; the adapter reports `.unconfirmed` once it gives
    /// up waiting, after a delay drawn from the window.
    case silent(after: SimWindow)
    /// The OS took the request first.
    case acceptFirst
}

/// A fake power adapter's script.
package struct PowerScript: Sendable {
    package var offer: Availability<PowerOffer>
    /// Reports after `perform`, each a delay drawn from `after` past the previous one.
    package var steps: [(after: SimWindow, report: PowerReport)]
    package var onCancel: CancelBehavior

    package init(
        offer: Availability<PowerOffer> = .available(PowerOffer(actions: [.shutdown, .restart], asksAppsToQuit: true)),
        steps: [(after: SimWindow, report: PowerReport)] = [
            (.ms(20) ... .ms(80), .accepted), (.ms(50) ... .ms(150), .askingApps), (.ms(100) ... .ms(300), .handedOff),
        ],
        onCancel: CancelBehavior = .confirm(after: .ms(20) ... .ms(80))
    ) {
        self.offer = offer
        self.steps = steps
        self.onCancel = onCancel
    }

    package static let absent = PowerScript(offer: .absent(.notImplemented, debugDetail: ""), steps: [])
}

/// A fake installer's script and slot metadata.
package struct InstallerSpec: Sendable {
    package var formats: [PayloadFormat] = [.executable]
    package var rejectedHash: Data?
    /// Delay before each `.consumed`.
    package var consumeDelay: SimWindow = .us(20) ... .us(80)
    /// Delay before `.installed` or `.rejected`.
    package var installDelay: SimWindow = .ms(10) ... .ms(30)
    /// Fail mid-stream after this many bytes with this code.
    package var failAfter: (bytes: Int, code: ErrorCode)?
    /// The version the payload installs hangs before Hello; the rollback check reverts it.
    package var newVersionHangs = false

    package init() {}
}

/// One simulated agent process's configuration.
package struct PeerSpec: Sendable {
    package var claim: PeerClaim
    package var state: PeerSessionState
    package var power = PowerScript()
    package var logs = true
    package var installer: InstallerSpec?
    package var protocolVersion: UInt32 = 1
    /// A fixed instance id; otherwise each process start draws one.
    package var instanceID: Data?
    package var startAt: SimTime = 0

    package init(claim: PeerClaim, state: PeerSessionState) {
        self.claim = claim
        self.state = state
    }

    /// A Linux session peer of USER scope owning the console.
    package static func session(_ sessionID: String = "c1", console: ConsoleState = .on, scope: InstallScope = .user)
        -> PeerSpec
    {
        PeerSpec(
            claim: PeerClaim(
                role: .sessionPeer, scope: scope, os: .linux, osVersion: "24.04", architecture: .arm64,
                payloadHash: Data(repeating: 0xA1, count: 32), versionLabel: "2.0"),
            state: PeerSessionState(console: console, sessionID: sessionID, userName: "user"))
    }

    /// A Linux system peer.
    package static func system(console: ConsoleState = .on, consoleSessionID: String = "c1") -> PeerSpec {
        PeerSpec(
            claim: PeerClaim(
                role: .systemPeer, scope: .system, os: .linux, osVersion: "24.04", architecture: .arm64,
                payloadHash: Data(repeating: 0xB1, count: 32), versionLabel: "2.0"),
            state: PeerSessionState(console: console, consoleSessionID: consoleSessionID))
    }
}

/// What a run expects of liveness (property 7 of `PropertyChecker`).
package enum LivenessExpectation: Sendable, Equatable {
    /// No unresponsive verdict, no liveness close and no Hello timeout anywhere.
    case quiet
    /// The scenario judges liveness itself.
    case scenarioChecked
}

/// A span of world time; the world draws one instant in it from the run's seed.
package typealias SimWindow = ClosedRange<SimTime>

extension ClosedRange where Bound == SimTime {
    /// The window holding only `time`.
    package static func at(_ time: SimTime) -> Self { time...time }
}

/// A fault the world injects. Each starts at an instant the world draws from
/// its window, so the seed moves the fault against the protocol's state; a
/// fault that never takes effect fails the run.
package enum Fault: Sendable {
    /// The link's direction carries a byte count drawn from `afterByte`, then the transport ends both ways.
    case cut(PipeDirection, afterByte: ClosedRange<Int>)
    /// The peer's process dies.
    case peerDeath(peer: Int, in: SimWindow)
    /// The peer's process runs nothing for `for`.
    case peerHang(peer: Int, in: SimWindow, for: SimTime)
    /// One side of a link reads nothing for `for`.
    case readerStall(SimSide, link: Int, in: SimWindow, for: SimTime)
    /// One side's consumer of `kind` on the peer's link holds what it is delivered for `for`: the peer's
    /// installer for UPDATE_PULL, or either side's bulk test sink for a test kind.
    case consumerStall(SimSide, StreamKind, peer: Int, in: SimWindow, for: SimTime)
    /// Every peer is paused, and the host is told, for `for`.
    case vmFreeze(in: SimWindow, for: SimTime, guestClockJumps: Bool)
    /// The host sleeps for `for`, its VMs paused first.
    case hostSleep(in: SimWindow, for: SimTime)
    /// The process's clock steps by `by` nanoseconds.
    case clockStep(SimProcess, in: SimWindow, by: Int64)
}

/// A link direction.
package enum PipeDirection: Sendable, Equatable {
    case hostToPeer(link: Int)
    case peerToHost(link: Int)
}

/// A link's two ends.
package enum SimSide: Sendable, Equatable {
    case host, peer
}

/// A simulated process.
package enum SimProcess: Sendable, Equatable {
    case host
    case peer(Int)
}

/// World-wide options.
package struct SimOptions: Sendable {
    package var hostPolicy = PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)])
    package var bundles: [BundledPayload] = []
    package var receiverPolicy = ReceiverPolicy.production
    package var testKinds = false
    package var hostToPeer = PipeParameters.hostToGuest
    package var peerToHost = PipeParameters.guestToHost
    /// Hostile runs may close with FLOW_CONTROL_ERROR and the like.
    package var hostile = false
    package var liveness = LivenessExpectation.quiet
    package var faults: [Fault] = []
    /// Bytes each accepted test-kind stream sends.
    package var testBulkBytes = 0
    package var payloadSourceDelay: SimTime = .us(20)

    package init() {}
}
