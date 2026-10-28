#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// A frame in a stream's own FIFO (§3.5 step 7). Its credit was taken when it
/// was queued, so it leaves whenever its turn comes.
enum QueuedFrame: Sendable {
    case open(Data)
    case window(UInt32)
    case message(Data)
    case data(Data)
    case end(Data)
}

/// One stream's state on this side.
struct StreamRecord: Sendable {
    let id: StreamID
    let descriptor: StreamKindDescriptor
    /// This side opened it.
    let isLocal: Bool
    /// The machines know of it: a local open, or a remote OPEN that passed §3.6.
    /// A refused OPEN is a record only to carry its RESET.
    let isAccepted: Bool
    var phase: StreamPhase = .open
    var remoteEndBody = Data()

    // Sending
    var sendWindow = Limits.initialStreamWindow
    var queue: [QueuedFrame] = []
    var queueHead = 0
    /// Its OPEN has been handed out (always, for a stream the far side opened).
    var openHandedOut: Bool
    var pendingReset: WireError?
    var queuedRaw = 0
    var unsentMessages = 0
    /// The S4 predicate held at the last check, so `.writable` fires on its rising edge.
    var wasWritable = false

    // Receiving
    var receiveRemaining = Limits.initialStreamWindow
    let receiveTarget: Int
    var heldRaw = 0
    var unreturned = 0
    var pendingWindow = 0
    var returnBucket: TokenBucket?

    var kind: StreamKind { descriptor.kind }
    var owner: KindOwner { descriptor.owner }
    var sending: StreamDirection { descriptor.sending(asOpener: isLocal) }
    var receiving: StreamDirection { descriptor.receiving(asOpener: isLocal) }

    /// This side may still queue DATA or END.
    var canSend: Bool { phase == .open || phase == .remoteEnded }
    /// The far side may still send DATA, so stream credit is still returned.
    var canReceive: Bool { phase == .open || phase == .localEnded }

    var hasQueuedFrames: Bool { queueHead < queue.count }

    /// Still counted against the far side's or this side's limit (§3.3): not
    /// closed, or closed with this side's last frame not yet handed out.
    var holdsSlot: Bool { phase != .closed || hasQueuedFrames || pendingReset != nil }

    /// The record can go: closed, nothing left to send.
    var isRetired: Bool { phase == .closed && !hasQueuedFrames && pendingReset == nil && pendingWindow == 0 }

    var replenishThreshold: Int { receiveTarget / 4 }

    /// When the credit-return bucket next allows a WINDOW, if one is owed.
    var creditReturnWake: CoreInstant? {
        guard let returnBucket, canReceive, unreturned >= replenishThreshold,
            returnBucket.tokens < replenishThreshold
        else { return nil }
        return returnBucket.instant(holding: replenishThreshold)
    }

    init(
        id: StreamID, descriptor: StreamKindDescriptor, isLocal: Bool, isAccepted: Bool, bulkTarget: Int
    ) {
        self.id = id
        self.descriptor = descriptor
        self.isLocal = isLocal
        self.isAccepted = isAccepted
        openHandedOut = !isLocal
        receiveTarget =
            descriptor.receiving(asOpener: isLocal) == .rawData ? bulkTarget : Limits.initialStreamWindow
    }

    mutating func enqueue(_ frame: QueuedFrame) {
        queue.append(frame)
    }

    mutating func popFrame() -> QueuedFrame {
        let frame = queue[queueHead]
        queueHead += 1
        if queueHead == queue.count {
            queue.removeAll(keepingCapacity: true)
            queueHead = 0
        }
        return frame
    }

    var frontFrame: QueuedFrame? { hasQueuedFrames ? queue[queueHead] : nil }
}
