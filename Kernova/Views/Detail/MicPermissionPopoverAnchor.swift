import AppKit
import SwiftUI

/// SwiftUI↔AppKit bridge for the microphone-permission info popover.
///
/// Place via `.background(MicPermissionPopoverAnchor(isPresented:))` on the
/// SwiftUI trigger button. The popover content is fully AppKit
/// (``MicrophonePermissionPopoverContentViewController``); only this bridge
/// is SwiftUI-shaped.
///
/// No delegate, no view-model wiring — the popover is purely informational
/// (steps for granting mic permission via System Settings), so the only
/// outbound event is "user dismissed it." `PopoverPresenter.onClose` resets
/// the `isPresented` binding on any dismissal (click-outside, Escape, or
/// programmatic `close()`).
struct MicPermissionPopoverAnchor: NSViewRepresentable {
    /// Drives popover presentation.
    ///
    /// Set to `true` to show the popover; the coordinator flips it back to
    /// `false` when the popover dismisses.
    @Binding var isPresented: Bool

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
        coordinator.bindingResetter = { isPresented = false }

        if isPresented && !coordinator.presenter.isShown {
            coordinator.show(from: nsView)
        } else if !isPresented && coordinator.presenter.isShown {
            coordinator.presenter.close()
        }
    }

    /// Bridge coordinator: owns the ``PopoverPresenter`` and resets the
    /// SwiftUI binding when the popover dismisses.
    @MainActor
    final class Coordinator {
        let presenter = PopoverPresenter()
        var bindingResetter: (() -> Void)?

        init() {
            presenter.onClose = { [weak self] in
                self?.bindingResetter?()
            }
        }

        func show(from anchor: NSView) {
            let vc = MicrophonePermissionPopoverContentViewController()
            presenter.show(content: vc, from: anchor, preferredEdge: .minY)
        }
    }
}
