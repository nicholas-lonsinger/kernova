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
    /// The OS confirms nothing started, after this delay.
    case confirm(after: SimTime)
    /// The adapter cannot tell; it reports nothing.
    case silent
    /// The OS took the request first, after this delay.
    case acceptFirst(after: SimTime)
}

/// A fake power adapter's script.
package struct PowerScript: Sendable {
    package var offer: Availability<PowerOffer>
    /// Reports after `perform`, each `after` the previous one.
    package var steps: [(after: SimTime, report: PowerReport)]
    package var onCancel: CancelBehavior

    package init(
        offer: Availability<PowerOffer> = .available(PowerOffer(actions: [.shutdown, .restart], asksAppsToQuit: true)),
        steps: [(after: SimTime, report: PowerReport)] = [
            (.ms(50), .accepted), (.ms(100), .askingApps), (.ms(200), .handedOff),
        ],
        onCancel: CancelBehavior = .confirm(after: .ms(50))
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
    package var consumeDelay: SimTime = .us(50)
    /// Delay before `.installed` or `.rejected`.
    package var installDelay: SimTime = .ms(20)
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

/// What a run expects of liveness (§10.3 property 7).
package enum LivenessExpectation: Sendable, Equatable {
    /// No unresponsive verdict, no liveness close and no Hello timeout anywhere.
    case quiet
    /// The scenario judges liveness itself.
    case scenarioChecked
}

/// The faults of §10.2.
package enum Fault: Sendable {
    case cut(PipeDirection, afterByte: Int)
    case peerDeath(peer: Int, at: SimTime)
    case peerHang(peer: Int, at: SimTime, for: SimTime)
    case readerStall(SimSide, link: Int, at: SimTime, for: SimTime)
    case consumerStall(peer: Int, at: SimTime, for: SimTime)
    case vmFreeze(at: SimTime, for: SimTime, guestClockJumps: Bool)
    case hostSleep(at: SimTime, for: SimTime)
    case clockStep(SimProcess, at: SimTime, by: Int64)
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
    /// The payload source returns this many bytes more (positive) or fewer than the manifest says.
    package var payloadSizeSkew = 0

    package init() {}
}
