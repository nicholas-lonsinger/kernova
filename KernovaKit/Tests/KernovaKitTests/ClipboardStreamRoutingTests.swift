import Testing

@testable import KernovaKit

/// Unit tests for the one routing rule every chunk-streamed channel shares —
/// which engine owns an abort, and whether a sender-bound one may be delivered
/// off the owner's actor.
@Suite("ClipboardStreamRouting")
struct ClipboardStreamRoutingTests {
    /// A transfer id the host receives (direction bit set) — one the guest is
    /// therefore sending.
    private let hostReceivedID = ClipboardTransferID.make(
        generation: 3, repIndex: 1, hostMinted: true)
    /// A transfer id the guest receives — one the host is sending.
    private let guestReceivedID = ClipboardTransferID.make(
        generation: 3, repIndex: 1, hostMinted: false)

    private func abortFrame(_ transferID: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardStreamAbort = .with {
            $0.transferID = transferID
            $0.code = ClipboardStreamAbortCode.superseded.rawValue
        }
        return frame
    }

    // MARK: - Abort ownership

    @Test("the host's receiver owns an abort for an id the host receives")
    func hostReceiverOwnsHostReceivedIDs() {
        #expect(ClipboardStreamRouting.receiverOwns(hostReceivedID, role: .host))
        #expect(!ClipboardStreamRouting.receiverOwns(guestReceivedID, role: .host))
    }

    @Test("the guest's receiver owns the mirror set")
    func guestReceiverOwnsGuestReceivedIDs() {
        #expect(ClipboardStreamRouting.receiverOwns(guestReceivedID, role: .guest))
        #expect(!ClipboardStreamRouting.receiverOwns(hostReceivedID, role: .guest))
    }

    // MARK: - Delivery

    @Test("a sender-bound abort rides the control hop when the owner asks it to")
    func routesSenderAbortsAsControlFrames() {
        var control: [Frame] = []
        ClipboardStreamRouting.route(
            abortFrame(guestReceivedID), role: .host, sender: nil, receiver: nil,
            senderAbortDelivery: .viaControlFrame, onControlFrame: { control.append($0) })

        #expect(control.count == 1)
        if case .clipboardStreamAbort(let abort) = control.first?.payload {
            #expect(abort.transferID == guestReceivedID)
        } else {
            Issue.record("Expected the abort to reach the control-frame handler")
        }
    }

    @Test("a receiver-bound abort never reaches the control hop")
    func keepsReceiverAbortsOffTheControlHop() {
        var control: [Frame] = []
        ClipboardStreamRouting.route(
            abortFrame(hostReceivedID), role: .host, sender: nil, receiver: nil,
            senderAbortDelivery: .viaControlFrame, onControlFrame: { control.append($0) })

        #expect(control.isEmpty)
    }

    @Test("a sender-bound abort is delivered directly when the owner allows it")
    func routesSenderAbortsDirectly() {
        var control: [Frame] = []
        ClipboardStreamRouting.route(
            abortFrame(hostReceivedID), role: .guest, sender: nil, receiver: nil,
            senderAbortDelivery: .direct, onControlFrame: { control.append($0) })

        #expect(control.isEmpty)
    }

    @Test("stream payloads never reach the control hop, and everything else does")
    func separatesStreamPayloadsFromControlFrames() {
        var control: [Frame] = []
        let record: (Frame) -> Void = { control.append($0) }

        for payload in [
            Frame.OneOf_Payload.clipboardStreamBegin(Kernova_V1_ClipboardStreamBegin()),
            .clipboardChunk(Kernova_V1_ClipboardChunk()),
            .clipboardStreamEnd(Kernova_V1_ClipboardStreamEnd()),
            .clipboardStreamAck(Kernova_V1_ClipboardStreamAck()),
        ] {
            var frame = Frame()
            frame.protocolVersion = 1
            frame.payload = payload
            ClipboardStreamRouting.route(
                frame, role: .host, sender: nil, receiver: nil,
                senderAbortDelivery: .viaControlFrame, onControlFrame: record)
        }
        #expect(control.isEmpty)

        var offer = Frame()
        offer.protocolVersion = 1
        offer.dropOffer = Kernova_V1_DropOffer()
        ClipboardStreamRouting.route(
            offer, role: .host, sender: nil, receiver: nil,
            senderAbortDelivery: .viaControlFrame, onControlFrame: record)
        #expect(control.count == 1)
    }
}
