import Testing
import Foundation
import KernovaTestSupport

@testable import KernovaKit

@Suite("ControlChannelFrames")
struct ControlChannelFramesTests {
    // MARK: - Builders

    @Test("Hello carries the control-channel defaults and the sender's version")
    func helloCarriesTheDefaults() throws {
        let frame = Frame.controlHello(agentVersion: "1.2.3")

        #expect(frame.protocolVersion == 1)
        guard case .hello(let hello) = frame.payload else {
            throw TestFailure("Expected a hello payload, got \(String(describing: frame.payload))")
        }
        #expect(hello.serviceVersion == 1)
        #expect(hello.capabilities == KernovaCapability.controlChannelDefaults)
        #expect(hello.agentInfo.os == "macOS")
        #expect(hello.agentInfo.osVersion == KernovaOSVersion.current)
        #expect(hello.agentInfo.agentVersion == "1.2.3")
        // The guest omits it, and an empty field is what the peer reads as
        // "no bundled agent version known".
        #expect(hello.bundledAgentVersion.isEmpty)
    }

    @Test("Hello reports a bundled agent version when the sender has one")
    func helloCarriesTheBundledVersion() throws {
        let frame = Frame.controlHello(agentVersion: "host", bundledAgentVersion: "2.0.0")

        guard case .hello(let hello) = frame.payload else {
            throw TestFailure("Expected a hello payload, got \(String(describing: frame.payload))")
        }
        #expect(hello.bundledAgentVersion == "2.0.0")
        #expect(hello.agentInfo.agentVersion == "host")
    }

    @Test("Heartbeat carries its nonce")
    func heartbeatCarriesItsNonce() throws {
        let frame = Frame.controlHeartbeat(nonce: 42)

        #expect(frame.protocolVersion == 1)
        guard case .heartbeat(let heartbeat) = frame.payload else {
            throw TestFailure("Expected a heartbeat payload, got \(String(describing: frame.payload))")
        }
        #expect(heartbeat.nonce == 42)
    }

    @Test("PolicyUpdate carries every toggle the guest enforces")
    func policyUpdateCarriesEveryToggle() throws {
        let frame = Frame.controlPolicyUpdate(
            logForwardingEnabled: true,
            clipboardSharingEnabled: false,
            clipboardMaxPasteBytes: 1_234,
            dropFilesEnabled: true)

        #expect(frame.protocolVersion == 1)
        guard case .policyUpdate(let policy) = frame.payload else {
            throw TestFailure(
                "Expected a policyUpdate payload, got \(String(describing: frame.payload))")
        }
        #expect(policy.logForwardingEnabled)
        #expect(!policy.clipboardSharingEnabled)
        #expect(policy.clipboardMaxPasteBytes == 1_234)
        #expect(policy.dropFilesEnabled)
    }

    // MARK: - Classification

    @Test("A frame from an unspoken protocol version is classified, not read")
    func classifiesUnsupportedVersion() {
        var frame = Frame.controlHeartbeat(nonce: 1)
        frame.protocolVersion = 7

        let inbound = ControlChannelInbound.classify(frame)

        #expect(inbound == .unsupportedVersion(7))
        // The one classification that says nothing about the peer's health: the
        // frame was never parsed.
        #expect(!inbound.isLivenessSignal)
    }

    @Test("Version zero — an unset field — is unsupported too")
    func classifiesUnsetVersion() {
        #expect(ControlChannelInbound.classify(Frame()) == .unsupportedVersion(0))
    }

    @Test("Hello classifies to the handshake it carries")
    func classifiesHello() throws {
        let frame = Frame.controlHello(agentVersion: "1.0.0", bundledAgentVersion: "1.1.0")

        guard case .hello(let hello) = ControlChannelInbound.classify(frame) else {
            throw TestFailure("Expected a hello classification")
        }
        #expect(hello.agentInfo.agentVersion == "1.0.0")
        #expect(hello.bundledAgentVersion == "1.1.0")
    }

    @Test("Heartbeat classifies to its arrival alone")
    func classifiesHeartbeat() {
        let inbound = ControlChannelInbound.classify(Frame.controlHeartbeat(nonce: 9))

        #expect(inbound == .heartbeat)
        #expect(inbound.isLivenessSignal)
    }

    @Test("Error classifies to the peer's report")
    func classifiesError() throws {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.error = Kernova_V1_Error.with {
            $0.code = "boom"
            $0.message = "detail"
        }

        guard case .error(let error) = ControlChannelInbound.classify(frame) else {
            throw TestFailure("Expected an error classification")
        }
        #expect(error.code == "boom")
        #expect(error.message == "detail")
    }

    @Test("PolicyUpdate classifies to the snapshot it carries")
    func classifiesPolicyUpdate() throws {
        let frame = Frame.controlPolicyUpdate(
            logForwardingEnabled: true, clipboardSharingEnabled: true,
            clipboardMaxPasteBytes: 0, dropFilesEnabled: false)

        guard case .policyUpdate(let policy) = ControlChannelInbound.classify(frame) else {
            throw TestFailure("Expected a policyUpdate classification")
        }
        #expect(policy.logForwardingEnabled)
        #expect(policy.clipboardSharingEnabled)
    }

    @Test("A payload from another channel classifies as wrong port")
    func classifiesWrongPort() {
        let offer = Frame.clipboardOffer(generation: 1, reps: [], isConcealed: false)

        let inbound = ControlChannelInbound.classify(offer)

        #expect(inbound == .wrongPort)
        // A peer talking out of turn is still a peer that is talking.
        #expect(inbound.isLivenessSignal)
    }

    @Test("A frame with no payload classifies as wrong port")
    func classifiesEmptyPayload() {
        var frame = Frame()
        frame.protocolVersion = 1

        #expect(ControlChannelInbound.classify(frame) == .wrongPort)
    }
}
