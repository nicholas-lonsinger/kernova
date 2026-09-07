import AppKit
import Foundation
import KernovaKit
import UniformTypeIdentifiers
import os

/// Reads a wire client's named file through the sandbox, asking the user for it
/// when the container does not already admit it.
///
/// A grant the user gives an open panel is the only way a sandboxed app reaches
/// a file nobody handed it, so the panel is the authority: whatever the user
/// picks is what the verb acts on, and a dismissed panel is a refusal.
///
/// No bookmark is captured here — a caller that needs the grant to outlive the
/// call mints one from the answered URL at the pick site.
@MainActor
final class PowerboxSourceAuthority: SandboxSourceAuthorizing {
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "PowerboxSourceAuthority")

    /// Brings the app forward, for the panel that is about to go up: a request
    /// arriving from a terminal has no window of its own, and a panel ordered in
    /// behind the app that asked for it has asked nobody anything.
    private let activate: () -> Void

    init(activate: @escaping () -> Void) {
        self.activate = activate
    }

    func readableURL(for url: URL, as source: SandboxedSource) async throws -> URL {
        guard !FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            return url
        }
        Self.logger.notice(
            "Asking for permission to read '\(url.lastPathComponent, privacy: .public)'")
        activate()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        switch source {
        case .vmBundle:
            panel.allowedContentTypes = [.kernovaVM]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            panel.prompt = "Import"
        case .sharedDirectory:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.prompt = "Share"
        }
        // The folder, not the item: a package URL here is ignored and the
        // panel opens wherever it last was (observed 2026-09-06, macOS 27).
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message =
            "Kernova needs your permission to read \u{201C}\(url.lastPathComponent)\u{201D}."

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
                verb: source.verb,
                message:
                    "Kernova was not given permission to read \u{201C}\(url.lastPathComponent)\u{201D}."
            )
        }
        return picked
    }
}

extension SandboxedSource {
    /// The verb a refused grant fails.
    fileprivate var verb: VMVerb {
        switch self {
        case .vmBundle: .importVM
        case .sharedDirectory: .editSharedDirectory
        }
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
