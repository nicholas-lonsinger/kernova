import AppKit

/// Drives a "choose a disk size" popover (``DiskSizePopoverContentViewController``)
/// from an AppKit anchor view and forwards the confirmed size to a closure.
///
/// One instance owns one popover slot — typically a stored property on the view
/// controller that hosts the anchor button. This is the pure-AppKit replacement
/// for the `Coordinator` that used to live inside the SwiftUI
/// `CreateStorageDiskPopoverAnchor` / `CreateRemovableMediaPopoverAnchor`
/// bridges: the `onConfirm` closure lets the host decide what to do with the
/// size (allocate an in-bundle disk, or present a save panel for external
/// media) without coupling this coordinator to the view model.
@MainActor
final class DiskSizePopoverCoordinator: DiskSizePopoverContentViewControllerDelegate {
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
        vc.delegate = self
        presenter.show(content: vc, from: anchor, preferredEdge: .minY)
    }

    // MARK: - DiskSizePopoverContentViewControllerDelegate

    func diskSizePopover(
        _ vc: DiskSizePopoverContentViewController,
        didConfirmSizeInGB sizeInGB: Int
    ) {
        // Close before invoking the action: the action may present an
        // NSSavePanel (removable media) or mutate the config (in-bundle disk),
        // and closing first lets the popover's dismissal animation complete
        // first — matching the former SwiftUI bridge's ordering.
        presenter.close()
        onConfirm(sizeInGB)
    }

    func diskSizePopoverDidCancel(_ vc: DiskSizePopoverContentViewController) {
        presenter.close()
    }
}
