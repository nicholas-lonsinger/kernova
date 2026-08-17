import Foundation

/// Routes the frames of a chunk-streamed channel between the streaming engine
/// and the owner's control-frame handler.
///
/// Every channel carrying `ClipboardStreamBegin`/`Chunk`/`End`/`Ack`/`Abort` —
/// the clipboard channel on both sides, the drop channel on both sides — has the
/// same routing rule, and it is a rule with one subtlety that must not be
/// restated per channel: which engine owns an abort, decided by the transfer
/// id's direction bit read from the routing side's point of view.
///
/// The high-frequency payloads go straight to the thread-safe engine so a
/// multi-GB transfer's chunk and ack traffic never reaches the owner's actor.
public enum ClipboardStreamRouting {
    /// Which end of the wire the routing side is, which is what makes the
    /// transfer id's direction bit readable: the host receives on ids that carry
    /// it and sends on ids that do not, and the guest is the mirror.
    public enum Role: Sendable {
        /// The Mac running Kernova.
        case host
        /// The agent inside the VM.
        case guest
    }

    /// Hands `frame` to `sender`/`receiver` when it is a stream payload, and to
    /// `onControlFrame` otherwise.
    ///
    /// `onControlFrame` is called on the routing thread; an owner confined to an
    /// actor hops inside it. An abort naming a transfer this side is *sending*
    /// goes through it too, rather than to the sender here: every owner registers
    /// its outbound transfers on its own actor, and an abort handled
    /// synchronously on the routing thread can overtake that registration and
    /// no-op on an id the engine does not know yet, leaving a cancelled transfer
    /// streaming. [H3]
    public static func route(
        _ frame: Frame,
        role: Role,
        sender: ClipboardStreamSender?,
        receiver: ClipboardStreamReceiver?,
        onControlFrame: (Frame) -> Void
    ) {
        switch frame.payload {
        case .clipboardStreamBegin(let begin):
            receiver?.handleBegin(begin)
        case .clipboardChunk(let chunk):
            receiver?.handleChunk(chunk)
        case .clipboardStreamEnd(let end):
            receiver?.handleEnd(end)
        case .clipboardStreamAck(let ack):
            sender?.handleAck(
                transferID: ack.transferID, bytesConsumed: ack.bytesConsumed,
                windowBytes: ack.windowBytes)
        case .clipboardStreamAbort(let abort):
            if receiverOwns(abort.transferID, role: role) {
                receiver?.handleAbort(abort)
            } else {
                onControlFrame(frame)
            }
        default:
            onControlFrame(frame)
        }
    }

    /// Whether `transferID` names a transfer this side is receiving, so an abort
    /// for it belongs to the receiver rather than the sender.
    public static func receiverOwns(_ transferID: UInt64, role: Role) -> Bool {
        ClipboardTransferID.hostReceives(transferID) == (role == .host)
    }
}
