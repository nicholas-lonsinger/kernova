import AppKit
import SwiftUI

/// SwiftUI↔AppKit bridge that anchors the AppKit Create Disk popover to a
/// SwiftUI trigger button.
///
/// Place via `.background(CreateDiskPopoverAnchor(...))` on the trigger
/// button — the representable inserts a zero-size anchor view behind the
/// button that ``PopoverPresenter`` uses as the popover's `relativeTo`
/// reference. The popover *content* is fully AppKit
/// (``CreateDiskPopoverContentViewController``); only this bridge is
/// SwiftUI-shaped, and that's expected: it's the SwiftUI side of the
/// migration boundary.
struct CreateDiskPopoverAnchor: NSViewRepresentable {
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
        // Zero intrinsic size; we're just a positioning anchor for the
        // surrounding SwiftUI button.
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
    final class Coordinator: CreateDiskPopoverContentViewControllerDelegate {
        let presenter = PopoverPresenter()
        var instance: VMInstance?
        var viewModel: VMLibraryViewModel?
        var bindingResetter: (() -> Void)?

        init() {
            presenter.onClose = { [weak self] in
                self?.bindingResetter?()
            }
        }

        func show(from anchor: NSView) {
            let vc = CreateDiskPopoverContentViewController(
                availableSizes: VMGuestOS.allDiskSizes,
                defaultSizeInGB: VMGuestOS.defaultDiskSizeInGB
            )
            vc.delegate = self
            presenter.show(content: vc, from: anchor, preferredEdge: .maxY)
        }

        // MARK: - CreateDiskPopoverContentViewControllerDelegate

        func createDiskPopover(
            _ vc: CreateDiskPopoverContentViewController,
            didConfirmSizeInGB sizeInGB: Int
        ) {
            if let instance, let viewModel {
                viewModel.createStorageDisk(for: instance, sizeInGB: sizeInGB)
            }
            presenter.close()
        }

        func createDiskPopoverDidCancel(_ vc: CreateDiskPopoverContentViewController) {
            presenter.close()
        }
    }
}
