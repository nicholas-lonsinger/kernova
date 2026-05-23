import AppKit
import SwiftUI

/// SwiftUI↔AppKit bridge that anchors the AppKit Create Storage Disk popover
/// to a SwiftUI trigger button.
///
/// Place via `.background(CreateStorageDiskPopoverAnchor(...))` on the
/// trigger button — the representable inserts a zero-size anchor view
/// behind the button that ``PopoverPresenter`` uses as the popover's
/// `relativeTo` reference. The popover *content* is fully AppKit
/// (``DiskSizePopoverContentViewController``); only this bridge is
/// SwiftUI-shaped, and that's expected: it's the SwiftUI side of the
/// migration boundary.
///
/// The Create action forwards to `viewModel.createStorageDisk(for:sizeInGB:)`
/// which allocates an ASIF sparse disk image *inside* the VM bundle. For
/// the user-chosen-location case (Removable Media), use
/// ``CreateRemovableMediaPopoverAnchor`` instead.
struct CreateStorageDiskPopoverAnchor: NSViewRepresentable {
    /// Drives popover presentation.
    ///
    /// Set to `true` to show the popover; the coordinator flips it back to
    /// `false` when the popover dismisses (via confirm, cancel,
    /// click-outside, or Escape).
    @Binding var isPresented: Bool
    let instance: VMInstance
    let viewModel: VMLibraryViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        anchor.translatesAutoresizingMaskIntoConstraints = false
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.instance = instance
        coordinator.viewModel = viewModel
        coordinator.bindingResetter = { isPresented = false }

        if isPresented && !coordinator.presenter.isShown {
            coordinator.show(from: nsView)
        } else if !isPresented && coordinator.presenter.isShown {
            coordinator.presenter.close()
        }
    }

    /// Bridge coordinator: implements the popover content's delegate
    /// protocol, owns the ``PopoverPresenter``, and forwards Create actions
    /// to `viewModel.createStorageDisk(for:sizeInGB:)`.
    @MainActor
    final class Coordinator: DiskSizePopoverContentViewControllerDelegate {
        let presenter = PopoverPresenter()
        var instance: VMInstance?
        var viewModel: VMLibraryViewModel?
        var bindingResetter: (() -> Void)?

        init() {
            // Fires on every popover dismissal — user-driven
            // (click-outside, Escape) and programmatic
            // (`presenter.close()` from `dismiss()`). For delegate-driven
            // paths `dismiss()` also resets the binding *before* closing
            // to defend against a SwiftUI re-render bouncing the popover
            // back open; this onClose re-runs the resetter, but the
            // boolean write is idempotent so the second call is harmless.
            presenter.onClose = { [weak self] in
                self?.bindingResetter?()
            }
        }

        func show(from anchor: NSView) {
            let vc = DiskSizePopoverContentViewController(
                headline: "Create New Disk",
                caption:
                    "Creates an ASIF sparse disk image inside the VM bundle. Physical size grows as data is written.",
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
            if let instance, let viewModel {
                viewModel.createStorageDisk(for: instance, sizeInGB: sizeInGB)
            }
            dismiss()
        }

        func diskSizePopoverDidCancel(_ vc: DiskSizePopoverContentViewController) {
            dismiss()
        }

        /// Programmatic dismissal triggered by a delegate action (Confirm /
        /// Cancel).
        ///
        /// Resets the SwiftUI binding **before** starting the close
        /// animation so any SwiftUI re-render triggered by the action's
        /// side effects (e.g. `createStorageDisk` mutating the VM config)
        /// doesn't see `isPresented == true` while the popover is
        /// mid-close and bounce it back open. User-driven dismissals
        /// (click-outside, Escape) reset via `presenter.onClose` instead.
        private func dismiss() {
            bindingResetter?()
            presenter.close()
        }
    }
}
