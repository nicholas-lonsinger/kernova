import AppKit
import SwiftUI

extension View {
    /// Presents an AppKit `NSAlert` as a window-modal sheet when `isPresented` flips to `true`.
    ///
    /// The binding is reset to `false` after the user activates one of
    /// the alert's buttons.
    ///
    /// AppKit-side equivalent of SwiftUI's `.alert(_:isPresented:)`. Same
    /// trigger semantics; the alert chrome and modality come from
    /// `NSAlert.beginSheetModal(for:)`.
    func sheetAlert(
        isPresented: Binding<Bool>,
        configuration: @escaping () -> AlertConfiguration
    ) -> some View {
        modifier(SheetAlertModifier(isPresented: isPresented, configuration: configuration))
    }

    /// Presents an AppKit `NSAlert` as a window-modal sheet when
    /// `isPresented` flips to `true`, building the configuration from
    /// `data` at the moment of presentation.
    ///
    /// AppKit-side equivalent of SwiftUI's
    /// `.alert(_:isPresented:presenting:)`. If `data` is `nil` when the
    /// binding flips, the alert is skipped and the binding is reset.
    func sheetAlert<T>(
        isPresented: Binding<Bool>,
        presenting data: T?,
        configuration: @escaping (T) -> AlertConfiguration
    ) -> some View {
        let builder: () -> AlertConfiguration? = {
            guard let data else { return nil }
            return configuration(data)
        }
        return modifier(
            SheetAlertModifier(isPresented: isPresented) {
                builder() ?? AlertConfiguration(title: "", message: "", buttons: [])
            }
        )
    }
}

/// Backing modifier for ``View/sheetAlert(isPresented:configuration:)``.
///
/// Captures the host `NSWindow` via a tiny `NSViewRepresentable` and
/// presents an `NSAlert` as a sheet on that window whenever `isPresented`
/// transitions to `true`. The completion handler attached to
/// `presentSheetAlert(_:in:completion:)` resets the binding so the next
/// `false → true` transition presents cleanly.
private struct SheetAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let configuration: () -> AlertConfiguration

    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window = $0 })
            .onChange(of: isPresented) { _, newValue in
                guard newValue else { return }
                guard let window else {
                    // No window captured yet — drop the request and reset
                    // the binding rather than presenting against a nil
                    // window. Shouldn't happen in practice once the view
                    // is in the hierarchy.
                    isPresented = false
                    return
                }
                let config = configuration()
                if config.buttons.isEmpty {
                    // No buttons → nothing to show. Skip and reset.
                    isPresented = false
                    return
                }
                presentSheetAlert(config, in: window) {
                    isPresented = false
                }
            }
    }
}
