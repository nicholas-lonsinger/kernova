import AppKit
import SwiftUI

extension View {
    /// Presents the AppKit Delete-VM confirmation sheet as a window-modal
    /// sheet when `isPresented` flips to `true`.
    ///
    /// Counterpart to the prior SwiftUI `.sheet(isPresented:) { DeleteVMSheet(...) }`
    /// pattern. The popover content is fully AppKit
    /// (``DeleteVMSheetContentViewController``); only this bridge is
    /// SwiftUI-shaped.
    ///
    /// - Parameters:
    ///   - isPresented: Drives presentation. Reset to `false` after the
    ///     user activates Cancel, Move-to-Trash, or otherwise dismisses
    ///     the sheet.
    ///   - instance: The VM to confirm deletion of. If `nil` when
    ///     `isPresented` flips, the sheet is skipped.
    ///   - externals: External attachments to list in the sheet body.
    ///   - onCancel: Invoked when the user cancels.
    ///   - onConfirm: Invoked when the user confirms; the `Bool` parameter
    ///     is the final state of the "Also move these files to Trash"
    ///     checkbox.
    /// - Returns: A view that presents the Delete-VM sheet on demand.
    func deleteVMSheet(
        isPresented: Binding<Bool>,
        instance: VMInstance?,
        externals: [ExternalAttachment],
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Bool) -> Void
    ) -> some View {
        modifier(
            DeleteVMSheetModifier(
                isPresented: isPresented,
                instance: instance,
                externals: externals,
                onCancel: onCancel,
                onConfirm: onConfirm
            )
        )
    }
}

/// Backing modifier for ``View/deleteVMSheet(isPresented:instance:externals:onCancel:onConfirm:)``.
private struct DeleteVMSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let instance: VMInstance?
    let externals: [ExternalAttachment]
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void

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
        guard let window, let instance else {
            isPresented = false
            return
        }
        coordinator.onCancel = {
            onCancel()
            isPresented = false
        }
        coordinator.onConfirm = { trashExternals in
            onConfirm(trashExternals)
            isPresented = false
        }
        // `presenter.onClose` fires for any dismissal (button action OR
        // sheet ended externally); reset the binding so the next
        // `false → true` transition presents cleanly.
        coordinator.presenter.onClose = {
            if isPresented { isPresented = false }
        }

        let vc = DeleteVMSheetContentViewController(
            vmName: instance.name, externals: externals
        )
        vc.delegate = coordinator
        coordinator.presenter.show(content: vc, in: window)
    }

    /// Bridge coordinator: implements the sheet content's delegate and
    /// owns the ``SheetPresenter``.
    @MainActor
    final class Coordinator: NSObject, DeleteVMSheetContentViewControllerDelegate {
        let presenter = SheetPresenter()
        var onCancel: (() -> Void)?
        var onConfirm: ((Bool) -> Void)?

        func deleteVMSheetDidCancel(_ vc: DeleteVMSheetContentViewController) {
            presenter.close()
            onCancel?()
        }

        func deleteVMSheet(
            _ vc: DeleteVMSheetContentViewController,
            didConfirmTrashExternals trashExternals: Bool
        ) {
            presenter.close()
            onConfirm?(trashExternals)
        }
    }
}
