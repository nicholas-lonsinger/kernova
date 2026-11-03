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
    /// `code`, `message` and `itemFailure` describe a failure; all are omitted
    /// for a completed or cancelled drop.
    public static func dropComplete(
        generation: UInt64, outcome: Kernova_V1_DropComplete.Outcome,
        code: ClipboardErrorCode? = nil, message: String = "",
        itemFailure: ClipboardItemFailure? = nil
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropComplete = Kernova_V1_DropComplete.with {
            $0.generation = generation
            $0.outcome = outcome
            if let code { $0.code = code.rawValue }
            $0.message = message
            if let wire = itemFailure?.boundedWire { $0.itemFailure = wire }
        }
        return frame
    }
}
