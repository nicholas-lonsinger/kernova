import AppKit
import SwiftUI

extension View {
    /// Presents the AppKit Boot Order sheet (the draggable storage-disk
    /// reorder list) as a window-modal sheet when `isPresented` flips
    /// to `true`.
    ///
    /// Counterpart to the prior SwiftUI `.sheet(isPresented:) { StorageDiskReorderSheet(...) }`
    /// pattern. The sheet content is fully AppKit
    /// (``StorageDiskReorderSheetContentViewController``); only this
    /// bridge is SwiftUI-shaped.
    ///
    /// - Parameters:
    ///   - isPresented: Drives presentation. Reset to `false` after the
    ///     user activates Done or otherwise dismisses the sheet.
    ///   - disks: Initial disk ordering shown when the sheet opens.
    ///   - instance: The VM whose boot order is being edited (used for
    ///     subtitle formatting).
    ///   - fileMonitor: Live file-existence tracker, so missing-file
    ///     affordances on individual rows update without the user
    ///     re-opening the sheet.
    ///   - onReorder: Invoked after every successful drag-reorder with
    ///     the new ordering. Wire to the same write path used elsewhere
    ///     to persist storage-disk changes.
    /// - Returns: A view that presents the Boot Order sheet on demand.
    func storageDiskReorderSheet(
        isPresented: Binding<Bool>,
        disks: [StorageDisk],
        instance: VMInstance,
        fileMonitor: AttachmentFileMonitor,
        onReorder: @escaping ([StorageDisk]) -> Void
    ) -> some View {
        modifier(
            StorageDiskReorderSheetModifier(
                isPresented: isPresented,
                disks: disks,
                instance: instance,
                fileMonitor: fileMonitor,
                onReorder: onReorder
            )
        )
    }
}

/// Backing modifier for ``View/storageDiskReorderSheet(isPresented:disks:instance:fileMonitor:onReorder:)``.
private struct StorageDiskReorderSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let disks: [StorageDisk]
    let instance: VMInstance
    let fileMonitor: AttachmentFileMonitor
    let onReorder: ([StorageDisk]) -> Void

    @State private var window: NSWindow?
    @State private var coordinator = Coordinator()

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window = $0 })
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    showSheet()
                } else if coordinator.presenter.isShown {
                    coordinator.presenter.close()
                }
            }
    }

    private func showSheet() {
        guard let window else {
            isPresented = false
            return
        }
        coordinator.onReorder = { newOrdering in
            onReorder(newOrdering)
        }
        coordinator.onDismiss = {
            isPresented = false
        }
        // `presenter.onClose` fires for any dismissal (Done OR sheet
        // ended externally); reset the binding so the next
        // `false → true` transition presents cleanly.
        coordinator.presenter.onClose = {
            if isPresented { isPresented = false }
        }

        let vc = StorageDiskReorderSheetContentViewController(
            disks: disks, instance: instance, fileMonitor: fileMonitor
        )
        vc.delegate = coordinator
        coordinator.presenter.show(content: vc, in: window)
    }

    /// Bridge coordinator: implements the sheet content's delegate and
    /// owns the ``SheetPresenter``.
    @MainActor
    final class Coordinator: NSObject,
        StorageDiskReorderSheetContentViewControllerDelegate
    {
        let presenter = SheetPresenter()
        var onReorder: (([StorageDisk]) -> Void)?
        var onDismiss: (() -> Void)?

        func storageDiskReorderSheet(
            _ vc: StorageDiskReorderSheetContentViewController,
            didReorderTo disks: [StorageDisk]
        ) {
            onReorder?(disks)
        }

        func storageDiskReorderSheetDidDismiss(
            _ vc: StorageDiskReorderSheetContentViewController
        ) {
            presenter.close()
            onDismiss?()
        }
    }
}
