import AppKit
import Foundation
import KernovaCommandModel
import KernovaCore
import KernovaLogging
import UniformTypeIdentifiers

/// Gets the sandbox to admit a wire client's named file, asking the user for it
/// when the container does not already.
///
/// A grant the user gives an open panel is the only way a sandboxed app reaches
/// a file nobody handed it. The panel decides only whether the named file
/// becomes readable: an answer that covers it — the file itself or a folder
/// around it — admits it, and any other answer is a refusal.
///
/// No bookmark is captured here — a caller that needs the grant to outlive the
/// app's run mints one from the named URL.
@MainActor
final class PowerboxSourceAuthority: SandboxSourceAuthorizing {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "PowerboxSourceAuthority")

    func requireReadAccess(to url: URL, as source: SandboxedSource) async throws {
        guard !Self.isReadable(url) else { return }
        // A path the sandbox does not admit still answers whether anything is
        // at it (docs/research/2026-11-18-pasteboard-file-grants.md,
        // observation 8), and no grant makes a missing file readable.
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw CommandError.invalidArgument(
                "Nothing is at \u{201C}\(url.path(percentEncoded: false))\u{201D}.")
        }
        Self.logger.log(
            .notice,
            "Asking for permission to read '\(url.lastPathComponent, privacy: .public)'")
        // A request arriving from a terminal or a shortcut has no window of its
        // own, and a panel ordered in behind the app that asked has asked
        // nobody anything.
        try await ActivationRequester.awaitActivation()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        switch source {
        case .vmBundle:
            panel.allowedContentTypes = [.kernovaVM]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            // The folder, not the item: a package URL here is ignored and the
            // panel opens wherever it last was (observed 2026-09-06, macOS 27).
            panel.directoryURL = url.deletingLastPathComponent()
        case .sharedDirectory:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            // A folder panel answered with nothing selected answers the folder
            // it shows (observed 2026-11-26, macOS 27.2.1), so showing the
            // named one makes it what the default button grants.
            panel.directoryURL = url
        }
        panel.message =
            "Kernova needs your permission to read \u{201C}\(url.lastPathComponent)\u{201D}."

        let response = await withTaskCancellationHandler {
            await panel.begin()
        } onCancel: {
            // The caller is gone, and a panel nobody is waiting on is a
            // question left on the Mac's screen that no answer reaches. Ending
            // it the way its Cancel button does answers the `begin()` still in
            // flight with `.cancel`.
            Task { @MainActor in panel.cancel(nil) }
        }

        guard response == .OK, let picked = panel.url else {
            throw CommandError.operationFailed(
                verb: source.verb,
                message:
                    "Kernova was not given permission to read \u{201C}\(url.lastPathComponent)\u{201D}."
            )
        }
        guard Self.isReadable(url) else {
            throw CommandError.operationFailed(
                verb: source.verb,
                message:
                    "Kernova was given \u{201C}\(picked.path(percentEncoded: false))\u{201D}, and still can\u{2019}t read \u{201C}\(url.path(percentEncoded: false))\u{201D}."
            )
        }
    }

    private static func isReadable(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false))
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
