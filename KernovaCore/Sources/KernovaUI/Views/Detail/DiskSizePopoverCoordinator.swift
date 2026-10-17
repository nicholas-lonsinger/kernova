import AppKit
import KernovaCore
import KernovaKit

/// Drives a "choose a disk size" popover (``DiskSizePopoverContentViewController``)
/// from an AppKit anchor view and forwards the confirmed size to a closure.
///
/// One instance owns one popover slot — typically a stored property on the view
/// controller that hosts the anchor button.
@MainActor
final class DiskSizePopoverCoordinator {
    private let presenter = PopoverPresenter()
    private let headline: String
    private let caption: String
    private let onConfirm: (Int) -> Void

    init(headline: String, caption: String, onConfirm: @escaping (Int) -> Void) {
        self.headline = headline
        self.caption = caption
        self.onConfirm = onConfirm
    }

    /// Shows the size popover anchored below `anchor`.
    func show(from anchor: NSView) {
        let vc = DiskSizePopoverContentViewController(
            headline: headline,
            caption: caption,
            availableSizes: VMGuestOS.allDiskSizes,
            defaultSizeInGB: VMGuestOS.defaultDiskSizeInGB
        )
        vc.onConfirm = { [weak self] sizeInGB in
            guard let self else { return }
            // Close before invoking the action so the popover's dismissal
            // animation completes before the action presents an NSSavePanel
            // (removable media) or mutates the config (in-bundle disk).
            presenter.close()
            onConfirm(sizeInGB)
        }
        vc.onCancel = { [weak self] in self?.presenter.close() }
        presenter.show(content: vc, from: anchor, preferredEdge: .minY)
    }
}
