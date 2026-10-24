import Foundation

// MARK: - Control-frame builders

/// Builders for the control frames the clipboard and drop channels exchange.
///
/// Every one sets `protocol_version`, which both peers' consume loops filter on:
/// a frame built anywhere else can omit it and be silently dropped by the far
/// side.
extension Frame {
    /// A `ClipboardOffer` announcing `reps` under `generation`.
    public static func clipboardOffer(
        generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo], isConcealed: Bool
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.repInfo = reps
            $0.isConcealed = isConcealed
        }
        return frame
    }

    /// A `ClipboardRequest` pulling one representation of an offer.
    public static func clipboardRequest(
        generation: UInt64, transferID: UInt64, uti: String, maxAcceptByteCount: UInt64
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = generation
            $0.transferID = transferID
            $0.uti = uti
            $0.maxAcceptByteCount = maxAcceptByteCount
        }
        return frame
    }

    /// A `ClipboardRelease` retiring the offer for `generation`.
    public static func clipboardRelease(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardRelease = Kernova_V1_ClipboardRelease.with {
            $0.generation = generation
        }
        return frame
    }

    /// A `DropOffer` announcing the dropped items of `generation`.
    public static func dropOffer(
        generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo]
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropOffer = Kernova_V1_DropOffer.with {
            $0.generation = generation
            $0.repInfo = reps
        }
        return frame
    }

    /// A `DropRelease` calling off the drop for `generation`.
    public static func dropRelease(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropRelease = Kernova_V1_DropRelease.with {
            $0.generation = generation
        }
        return frame
    }

    /// A `DropComplete` reporting how the drop for `generation` ended.
    ///
    /// `code` and `message` describe a failure; both are omitted for a completed
    /// or cancelled drop.
    public static func dropComplete(
        generation: UInt64, outcome: Kernova_V1_DropComplete.Outcome,
        code: ClipboardErrorCode? = nil, message: String = ""
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropComplete = Kernova_V1_DropComplete.with {
            $0.generation = generation
            $0.outcome = outcome
            if let code { $0.code = code.rawValue }
            $0.message = message
        }
        return frame
    }

    /// A `DragOffer` announcing the items of the guest drag under `generation`.
    public static func dragOffer(
        generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo]
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dragOffer = Kernova_V1_DragOffer.with {
            $0.generation = generation
            $0.repInfo = reps
        }
        return frame
    }

    /// A `DragComplete` saying the host is done with the drag for `generation`.
    public static func dragComplete(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dragComplete = Kernova_V1_DragComplete.with { $0.generation = generation }
        return frame
    }

    /// A `DragRelease` withdrawing the guest drag for `generation`.
    public static func dragRelease(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dragRelease = Kernova_V1_DragRelease.with { $0.generation = generation }
        return frame
    }

    /// A `DragTake` asking the guest to hand the drag for `generation` over.
    public static func dragTake(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dragTake = Kernova_V1_DragTake.with { $0.generation = generation }
        return frame
    }

    /// A `DragCatcher` showing the guest's catcher for `generation` again, or
    /// standing it down.
    public static func dragCatcher(generation: UInt64, shown: Bool) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dragCatcher = Kernova_V1_DragCatcher.with {
            $0.generation = generation
            $0.shown = shown
        }
        return frame
    }

    /// A `DragHandOff` reporting one step of the hand-off for `generation`.
    public static func dragHandOff(generation: UInt64, step: ClipboardDragHandOffStep) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dragHandOff = Kernova_V1_DragHandOff.with {
            $0.generation = generation
            switch step {
            case .armed: $0.stage = .armed
            case .targeted: $0.stage = .targeted
            case .caught: $0.stage = .caught
            case .failed(let code, let message):
                $0.stage = .failed
                if let code { $0.code = code.rawValue }
                $0.message = message
            }
        }
        return frame
    }

    /// A `DragSizes` carrying the measured size of each folder in the guest
    /// drag under `generation`, keyed by the folder's index in its offer.
    public static func dragSizes(generation: UInt64, folderByteCounts: [Int: Int]) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dragSizes = Kernova_V1_DragSizes.with {
            $0.generation = generation
            for (repIndex, byteCount) in folderByteCounts {
                $0.folderByteCounts[UInt32(clamping: repIndex)] = UInt64(clamping: byteCount)
            }
        }
        return frame
    }
}
