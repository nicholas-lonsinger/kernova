import AppKit
import Foundation

/// Display-layer properties that distinguish preparing, cold-paused ("Suspended"), and live-paused ("Paused") states.
extension VMInstance {
    /// Display name that distinguishes preparing, cold-paused ("Suspended"), and live-paused ("Paused").
    var statusDisplayName: String {
        if let state = preparingState { return state.operation.displayLabel }
        return isColdPaused ? "Suspended" : status.displayName
    }

    /// Display color that distinguishes preparing (orange), cold-paused (orange), and live-paused (yellow).
    var statusDisplayColor: NSColor {
        if isPreparing { return .systemOrange }
        return isColdPaused ? .systemOrange : status.statusColor
    }

    /// Tooltip explaining the VM state variant, or `nil` for standard states.
    var statusToolTip: String? {
        if let state = preparingState { return state.operation.displayLabel }
        if status == .initialBoot { return "Click Start to install macOS" }
        guard status == .paused else { return nil }
        return isColdPaused
            ? "VM state is saved to disk"
            : "VM is paused in memory"
    }

    /// `true` when this VM has a `.downloadLatest` install context, a
    /// `.kernovadownload` in-progress bundle at the chosen path, and no
    /// completed IPSW yet at the same path.
    ///
    /// Drives the "Resume Install" label variant.
    var hasResumableInstallDownload: Bool {
        #if arch(arm64)
        guard let context = configuration.installContext,
            context.source == .downloadLatest,
            let destinationURL = context.downloadDestinationURL
        else { return false }
        let bundle = IPSWBundle(url: IPSWService.resumeBundleURL(for: destinationURL))
        return bundle.exists
            && !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false))
        #else
        return false
        #endif
    }
}
