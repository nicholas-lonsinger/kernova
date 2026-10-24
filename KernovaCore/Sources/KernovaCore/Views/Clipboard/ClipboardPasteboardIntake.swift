import Foundation
import KernovaKit
import KernovaLogging

/// What the intake made of a pasteboard: a cause and a count, never a sentence —
/// each surface words it for its own gesture.
package enum ClipboardIntakeResult: Equatable, Sendable {
    /// Usable content; `skipped` counts the gesture's items it leaves out
    /// because they could not be read.
    case content(ClipboardContent, skipped: Int)
    /// Nothing usable, and why.
    case rejected(ClipboardIntakeRefusal)
    /// Files whose bytes still have to be read off the main actor via
    /// `read(filesAt:)` before they become `.content`.
    ///
    /// Several URLs, in pasteboard order, for a multi-select copy/drag.
    /// `unresolved` counts the copied files that no longer exist, so
    /// `read(filesAt:)` can report them alongside the ones it fails itself.
    /// Never applied directly.
    case pendingFiles([URL], unresolved: Int)
}

/// Why a pasteboard yielded nothing usable.
///
/// Only `.unreadable` is a loss the user is owed a report for: items were there
/// and could not be read. Every other case is a policy verdict — nothing was
/// there to lose.
package enum ClipboardIntakeRefusal: Equatable, Sendable {
    /// The pasteboard held no item.
    case empty
    /// An `org.nspasteboard.*` privacy marker dropped the snapshot wholesale.
    case suppressed(ClipboardSnapshotPolicy.SkipReason)
    /// A text-only transport was handed something other than text.
    case textOnlyTransport
    /// The items held nothing shareable.
    case nothingShareable
    /// `count` items were there and none could be read.
    case unreadable(count: Int)
}

/// The host gesture a clipboard-window intake answers, which decides its wording.
package enum ClipboardIntakeGesture: Sendable {
    /// Paste — the button or responder-chain `paste:` — reading the Mac clipboard.
    case paste
    /// A drop on the clipboard window, a received file promise included.
    case drop
}

/// Reads a pasteboard for one of the host's gestures — the clipboard window's
/// Paste and drop, and the passthrough poll — into a cause and a count.
///
/// Every rule about what may cross lives in `ClipboardPasteboardReader`, shared
/// with the guest agent and the drop service. `message(for:gesture:)` and
/// `skipNote(count:)` are the clipboard window's wording; the passthrough poll
/// reports losses as transfer failures instead.
@MainActor
package enum ClipboardPasteboardIntake {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardPasteboardIntake")

    /// Reads `pasteboard` into clipboard content.
    package static func read(
        from pasteboard: any ClipboardReadPasteboard, allowsBinary: Bool
    ) -> ClipboardIntakeResult {
        switch ClipboardPasteboardReader.readSnapshot(from: pasteboard, allowsBinary: allowsBinary) {
        case .empty:
            return .rejected(.empty)
        case .suppressed(let reason):
            return .rejected(.suppressed(reason))
        case .textOnlyRefusal:
            return .rejected(.textOnlyTransport)
        case .pendingFiles(let urls, let unresolved):
            return .pendingFiles(urls, unresolved: unresolved)
        case .content(let content, let skipped):
            return .content(content, skipped: skipped)
        case .nothingOfferable(let lost, let unreadable):
            if lost > 0 {
                // Every file the copy named is gone and no inline flavor stood
                // in for one — the same total loss `read(filesAt:)` reports.
                return .rejected(.unreadable(count: lost))
            }
            // The inline snapshot reads item 0 only, so the representations
            // that wouldn't hand over are one item's.
            return .rejected(unreadable ? .unreadable(count: 1) : .nothingShareable)
        }
    }

    /// Resolves copied/dropped files and folders into content, off the main
    /// actor because the stat and the folder estimate walk are I/O.
    ///
    /// `unresolved` is the count `read(from:)` already dropped for having no
    /// file left on disk, folded into the same count so one report covers every
    /// item the copy lost on either side of the actor hop.
    package nonisolated static func read(
        filesAt urls: [URL], unresolved: Int = 0, allowsBinary: Bool
    ) async -> ClipboardIntakeResult {
        guard allowsBinary else { return .rejected(.textOnlyTransport) }
        let intake = ClipboardPasteboardReader.resolve(filesAt: urls, unresolved: unresolved)
        guard !intake.representations.isEmpty else {
            return .rejected(.unreadable(count: intake.skipped))
        }
        if intake.skipped > 0 {
            logger.log(
                .warning,
                "Skipped \(intake.skipped, privacy: .public) unreadable copied item(s)")
        }
        return .content(
            ClipboardContent(representations: intake.representations), skipped: intake.skipped)
    }

    /// The clipboard window's line for `refusal`, worded for `gesture`.
    package nonisolated static func message(
        for refusal: ClipboardIntakeRefusal, gesture: ClipboardIntakeGesture
    ) -> String {
        let paste = gesture == .paste
        switch refusal {
        case .empty:
            return paste ? "The Mac clipboard is empty" : "The drop was empty"
        case .suppressed(.transientSnapshot):
            return paste ? "Transient clipboard content isn't shared" : "Transient content isn't shared"
        case .suppressed(.autoGeneratedSnapshot):
            return paste
                ? "Auto-generated clipboard content isn't shared" : "Auto-generated content isn't shared"
        case .suppressed(.transientMarkerType), .suppressed(.fileReferenceType), .suppressed(.emptyData):
            // `disposition(forTypes:)` only ever suppresses with the two
            // snapshot reasons above; the rest are per-representation skips.
            return paste ? "This clipboard content isn't shared" : "This content isn't shared"
        case .textOnlyTransport:
            return "Only text can be shared with Linux guests"
        case .nothingShareable:
            return paste ? "The Mac clipboard has no shareable content" : "The drop has no shareable content"
        case .unreadable(let count):
            let noun = paste ? "copied" : "dropped"
            return count > 1 ? "Couldn't read the \(noun) items" : "Couldn't read the \(noun) item"
        }
    }

    /// The clipboard window's caveat for content that left `count` items out,
    /// or `nil` when it left none.
    package nonisolated static func skipNote(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Skipped \(count) unreadable item\(count == 1 ? "" : "s")"
    }
}
