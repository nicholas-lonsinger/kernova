import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI↔AppKit bridge that anchors the AppKit Create Removable Disk
/// popover to a SwiftUI trigger button.
///
/// Behaves like ``CreateStorageDiskPopoverAnchor`` but with two
/// flow-specific differences:
/// - The popover is captioned for *external* (user-chosen-location) media,
///   not in-bundle storage.
/// - On Create, the coordinator presents an `NSSavePanel` so the user can
///   choose where on disk to save the new image, then calls
///   `viewModel.createRemovableMedia(for:sizeInGB:destinationURL:)` with
///   the resolved URL.
///
/// `NSSavePanel.begin(completionHandler:)` is intentional (not
/// `runModal()`) so the popover-dismissal animation can complete before
/// the save panel appears — the same constraint the SwiftUI predecessor
/// observed.
struct CreateRemovableMediaPopoverAnchor: NSViewRepresentable {
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
    /// protocol, owns the ``PopoverPresenter``, and on confirm presents an
    /// `NSSavePanel` whose completion handler invokes
    /// `viewModel.createRemovableMedia(for:sizeInGB:destinationURL:)`.
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
                headline: "Create New Removable Disk",
                caption:
                    "Creates a writable ASIF sparse disk image at a location you choose, attached as a hot-pluggable USB drive. The file lives outside the VM bundle.",
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
            guard let instance, let viewModel else {
                dismiss()
                return
            }
            // Dismiss the popover first; the save panel is scheduled
            // asynchronously via `begin(completionHandler:)`, so AppKit can
            // finish the popover's close animation before the save panel
            // appears in the foreground.
            dismiss()
            presentSavePanel(for: instance, viewModel: viewModel, sizeInGB: sizeInGB)
        }

        func diskSizePopoverDidCancel(_ vc: DiskSizePopoverContentViewController) {
            dismiss()
        }

        /// Programmatic dismissal triggered by a delegate action (Confirm /
        /// Cancel).
        ///
        /// Resets the SwiftUI binding **before** starting the close
        /// animation so any SwiftUI re-render triggered by the action's
        /// side effects (e.g. `createRemovableMedia` mutating the VM
        /// config) doesn't see `isPresented == true` while the popover is
        /// mid-close and bounce it back open. User-driven dismissals
        /// (click-outside, Escape) reset via `presenter.onClose` instead.
        private func dismiss() {
            bindingResetter?()
            presenter.close()
        }

        private func presentSavePanel(
            for instance: VMInstance, viewModel: VMLibraryViewModel, sizeInGB: Int
        ) {
            let panel = NSSavePanel()
            panel.title = "Save Removable Disk"
            panel.message = "Choose where to save the new removable disk image."
            panel.prompt = "Create"
            panel.nameFieldStringValue = "\(instance.name) Removable Disk.asif"
            // Constrain to `.asif` — we only know how to allocate ASIF.
            // NSSavePanel appends the extension if the user omits it, and
            // rejects mismatched extensions since `allowsOtherFileTypes`
            // defaults to false.
            panel.allowedContentTypes = [.asif]
            panel.canCreateDirectories = true
            // Intentionally no `directoryURL` — NSSavePanel remembers the
            // user's last-used location, which is a better default than
            // forcing every invocation back to ~/Documents.

            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                viewModel.createRemovableMedia(
                    for: instance, sizeInGB: sizeInGB, destinationURL: url
                )
            }
        }
    }
}
