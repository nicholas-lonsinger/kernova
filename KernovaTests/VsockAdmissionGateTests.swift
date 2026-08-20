import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The feature-channel admission verdicts, judged where the listeners judge
/// them: a channel is admitted only while a published control handshake exists,
/// and clipboard and drop additionally require their negotiated capability.
@Suite("VsockAdmissionGate", .admissionGated)
struct VsockAdmissionGateTests {
    private let allRequirements: [FeatureChannelRequirement] = [
        .none, .clipboardStreaming, .dropFiles,
    ]

    /// The state a completed handshake with the bundled agent publishes.
    private func fullHandshake() -> VsockAdmissionGate.State {
        VsockAdmissionGate.State(
            handshakeComplete: true,
            capabilities: Set(KernovaCapability.controlChannelDefaults))
    }

    // MARK: - Verdicts

    @Test("Nothing is admitted before a handshake is published")
    func nothingAdmittedBeforePublish() {
        let gate = VsockAdmissionGate()
        for requirement in allRequirements {
            #expect(
                gate.admission(for: requirement)
                    == .notReady(reason: "no control channel has completed its handshake"))
        }
    }

    @Test("A handshake without the feature capabilities admits only the log channel")
    func handshakeAloneAdmitsLogOnly() {
        let gate = VsockAdmissionGate()
        gate.publish(VsockAdmissionGate.State(handshakeComplete: true))
        #expect(gate.admission(for: .none) == .admit)
        // Refused against a *completed* handshake, so the refusal names the peer.
        #expect(
            gate.admission(for: .clipboardStreaming)
                == .denied(
                    reason:
                        "the connected guest agent does not advertise \(KernovaCapability.clipboardTransferV3)"
                ))
        #expect(
            gate.admission(for: .dropFiles)
                == .denied(
                    reason:
                        "the connected guest agent does not advertise \(KernovaCapability.dropFilesV3)"
                ))
    }

    @Test("An advertised capability admits its channel and only its channel")
    func capabilityAdmitsItsOwnChannel() {
        let gate = VsockAdmissionGate()
        gate.publish(
            VsockAdmissionGate.State(
                handshakeComplete: true,
                capabilities: [KernovaCapability.clipboardTransferV3]))
        #expect(gate.admission(for: .none) == .admit)
        #expect(gate.admission(for: .clipboardStreaming) == .admit)
        if case .denied = gate.admission(for: .dropFiles) {
        } else {
            Issue.record("drop admission should be denied without \(KernovaCapability.dropFilesV3)")
        }
    }

    @Test("A full handshake admits every channel")
    func fullHandshakeAdmitsAll() {
        let gate = VsockAdmissionGate()
        gate.publish(fullHandshake())
        for requirement in allRequirements {
            #expect(gate.admission(for: requirement) == .admit)
        }
    }

    // MARK: - Transitions

    @Test("Publishing a settled state withdraws admission")
    func settledPublishWithdraws() {
        let gate = VsockAdmissionGate()
        gate.publish(fullHandshake())
        #expect(gate.admission(for: .clipboardStreaming) == .admit)

        // What the control service publishes when its channel settles.
        gate.publish(VsockAdmissionGate.State())
        for requirement in allRequirements {
            #expect(
                gate.admission(for: requirement)
                    == .notReady(reason: "no control channel has completed its handshake"))
        }
    }

    @Test("clear() withdraws admission")
    func clearWithdraws() {
        let gate = VsockAdmissionGate()
        gate.publish(fullHandshake())
        gate.clear()
        #expect(
            gate.admission(for: .none)
                == .notReady(reason: "no control channel has completed its handshake"))
    }

    @Test("A re-published handshake restores admission")
    func republishRestores() {
        let gate = VsockAdmissionGate()
        gate.publish(fullHandshake())
        gate.clear()
        gate.publish(fullHandshake())
        #expect(gate.admission(for: .dropFiles) == .admit)
    }

    // MARK: - Off-main reads

    @Test("Admission is readable off the main actor")
    func admissionReadsOffMain() async {
        let gate = VsockAdmissionGate()
        gate.publish(fullHandshake())
        let verdict = await offCooperativePool { gate.admission(for: .clipboardStreaming) }
        #expect(verdict == .admit)
    }
}
