import AppKit
import Foundation
import KernovaKit
import UniformTypeIdentifiers
import os

/// Reads an import's source through the sandbox, asking the user for the bundle
/// when the container does not already admit it.
///
/// A grant the user gives an open panel is the only way a sandboxed app reaches
/// a file nobody handed it, so the panel is the authority: whatever the user
/// picks is what gets imported, and a dismissed panel is a refusal.
///
/// No bookmark is captured — the source is copied into the library on the spot
/// and never opened again.
@MainActor
final class PowerboxImportAuthority: ImportSourceAuthorizing {
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "PowerboxImportAuthority")

    /// Brings the app forward, for the panel that is about to go up: a request
    /// arriving from a terminal has no window of its own, and a panel ordered in
    /// behind the app that asked for it has asked nobody anything.
    private let activate: () -> Void

    init(activate: @escaping () -> Void) {
        self.activate = activate
    }

    func readableURL(for url: URL) async throws -> URL {
        guard !FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            return url
        }
        Self.logger.notice(
            "Asking for permission to read '\(url.lastPathComponent, privacy: .public)' before importing it"
        )
        activate()

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.kernovaVM]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        // The folder, not the bundle: a package URL here is ignored and the
        // panel opens wherever it last was (observed 2026-09-06, macOS 27).
        panel.directoryURL = url.deletingLastPathComponent()
        panel.prompt = "Import"
        panel.message =
            "Kernova needs your permission to read \u{201C}\(url.lastPathComponent)\u{201D} before it can import it."

        let dismissal = PanelDismissal(panel)
        let response = await withTaskCancellationHandler {
            await panel.begin()
        } onCancel: {
            // The caller is gone, and a panel nobody is waiting on is a
            // question left on the Mac's screen that no answer reaches.
            dismissal.dismiss()
        }

        guard response == .OK, let picked = panel.url else {
            throw CommandError.operationFailed(
                verb: .importVM,
                message:
                    "Kernova was not given permission to read \u{201C}\(url.lastPathComponent)\u{201D}."
            )
        }
        return picked
    }
}

/// Takes a panel back down from wherever a cancellation lands.
///
/// `@unchecked Sendable`: a cancellation handler is isolated to nothing and
/// `NSOpenPanel` is main-actor bound, so this box is what crosses — the panel
/// itself is only ever touched back on the main actor.
private struct PanelDismissal: @unchecked Sendable {
    private let panel: NSOpenPanel

    init(_ panel: NSOpenPanel) {
        self.panel = panel
    }

    /// Ends the panel the way its Cancel button does, which answers the
    /// `begin()` still in flight with `.cancel`.
    func dismiss() {
        Task { @MainActor in panel.cancel(nil) }
    }
}
