import AppKit
import KernovaProtocol
import UniformTypeIdentifiers
import os

/// Result of reading a pasteboard into the clipboard buffer.
enum ClipboardIntakeResult: Equatable {
    /// Usable content. `note` carries a user-visible caveat when some
    /// representations were skipped (e.g. an oversized TIFF dropped while
    /// its PNG sibling survived).
    case content(ClipboardContent, note: String?)
    /// Nothing usable; `message` says why in user-facing terms.
    case rejected(message: String)
}

/// The single intake path for every host-side gesture that feeds the
/// clipboard buffer — the Paste button, responder-chain `paste:`, and
/// drag-and-drop — so all of them filter, cap, and reject identically.
///
/// Filtering and size caps come from `ClipboardSnapshotPolicy`, the same
/// policy the guest agent applies to its pasteboard poll.
@MainActor
enum ClipboardPasteboardIntake {
    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardPasteboardIntake")

    static let textOnlyTransportMessage = "Only text can be shared with Linux guests"

    /// Reads the first item of `pasteboard` into clipboard content.
    ///
    /// A single dragged file (`public.file-url`) is expanded: image files
    /// become an image representation, text files become text; other file
    /// types are rejected (generic file transfer is out of scope). With
    /// `allowsBinary == false` (text-only transports) only the plain-text
    /// representation is taken.
    static func read(from pasteboard: NSPasteboard, allowsBinary: Bool) -> ClipboardIntakeResult {
        guard let item = pasteboard.pasteboardItems?.first else {
            return .rejected(message: "The Mac clipboard is empty")
        }

        // A Finder file drag/copy carries a file URL, not the file's bytes —
        // expand it before the generic path (whose policy skips file URLs).
        if item.types.contains(.fileURL),
            let urlString = item.string(forType: .fileURL),
            let url = URL(string: urlString)
        {
            return read(fileAt: url, allowsBinary: allowsBinary)
        }

        guard allowsBinary else {
            guard let text = item.string(forType: .string), !text.isEmpty else {
                return .rejected(message: Self.textOnlyTransportMessage)
            }
            return .content(ClipboardContent(text: text), note: nil)
        }

        // Identity-based skips run before any data is read, mirroring the
        // guest agent's poll.
        let raw: [(uti: String, data: Data)] = item.types.compactMap { type in
            guard !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: type.rawValue) else {
                return nil
            }
            guard let data = item.data(forType: type) else { return nil }
            return (uti: type.rawValue, data: data)
        }
        let outcome = ClipboardSnapshotPolicy.evaluate(raw)

        if !outcome.skipped.isEmpty {
            let summary = outcome.skipped
                .map { "\($0.uti): \(String(describing: $0.reason))" }
                .joined(separator: ", ")
            logger.info("Pasteboard intake skipped: \(summary, privacy: .public)")
        }

        guard !outcome.content.isEmpty else {
            if outcome.skipped.contains(where: {
                if case .oversized = $0.reason { return true }
                if case .totalBudgetExceeded = $0.reason { return true }
                return false
            }) {
                return .rejected(
                    message:
                        "Clipboard content is too large to share (over \(DataFormatters.formatBytes(UInt64(ClipboardSnapshotPolicy.maxTotalByteCount))))"
                )
            }
            return .rejected(message: "The Mac clipboard has no shareable content")
        }

        let note: String? =
            outcome.skipped.contains(where: {
                if case .oversized = $0.reason { return true }
                if case .totalBudgetExceeded = $0.reason { return true }
                return false
            })
            ? "Some formats were too large to include" : nil

        return .content(outcome.content, note: note)
    }

    /// Reads a single file into clipboard content — the expansion used for
    /// dragged/copied `public.file-url` items and for files received from
    /// drag-and-drop file promises (screenshot thumbnail, Photos, browsers).
    ///
    /// Image files become one image representation, text files become text;
    /// other types are rejected (generic file transfer is out of scope).
    static func read(fileAt url: URL, allowsBinary: Bool) -> ClipboardIntakeResult {
        guard
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
            let type = values.contentType
        else {
            return .rejected(message: "Couldn't read the dropped file")
        }

        let fileSize = values.fileSize ?? 0
        guard fileSize <= ClipboardSnapshotPolicy.maxRepresentationByteCount else {
            return .rejected(
                message:
                    "File is too large to share (over \(DataFormatters.formatBytes(UInt64(ClipboardSnapshotPolicy.maxRepresentationByteCount))))"
            )
        }

        if type.conforms(to: .plainText) {
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
                return .rejected(message: "Couldn't read the dropped file as text")
            }
            return .content(ClipboardContent(text: text), note: nil)
        }

        if type.conforms(to: .image) {
            guard allowsBinary else {
                return .rejected(message: Self.textOnlyTransportMessage)
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                return .rejected(message: "Couldn't read the dropped file")
            }
            return .content(
                ClipboardContent(representations: [
                    .init(uti: type.identifier, data: data)
                ]),
                note: nil
            )
        }

        return .rejected(message: "Only image and text files can be shared")
    }
}
