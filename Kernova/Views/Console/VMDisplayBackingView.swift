import Cocoa
import Virtualization

/// Pure AppKit view containing a `VZVirtualMachineView` with built-in pause and transition overlays.
///
/// Used directly as `window.contentView` in the detached display window and layered on top of
/// SwiftUI content in the inline detail pane. Eliminates the need for `NSViewRepresentable`
/// bridging — `VZVirtualMachineView` stays entirely in AppKit.
@MainActor
final class VMDisplayBackingView: NSView {

    let machineView: VZVirtualMachineView = {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        return view
    }()

    /// Called when the user taps the resume button on the pause overlay.
    var onResume: (() -> Void)?

    private let pauseOverlay: NSVisualEffectView
    private let pauseButton: NSButton
    private let transitionOverlay: NSVisualEffectView
    private let transitionLabel: NSTextField
    private var pauseVisible = false
    private var transitionVisible = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        let (pause, button) = Self.makePauseOverlay()
        pauseOverlay = pause
        pauseButton = button
        let (transition, label) = Self.makeTransitionOverlay()
        transitionOverlay = transition
        transitionLabel = label

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        addFullSizeSubview(machineView)
        addFullSizeSubview(pauseOverlay)
        addFullSizeSubview(transitionOverlay)

        pauseOverlay.alphaValue = 0
        pauseOverlay.isHidden = true
        transitionOverlay.alphaValue = 0
        transitionOverlay.isHidden = true

        pauseButton.target = self
        pauseButton.action = #selector(resumeTapped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - State Updates

    /// Updates the displayed virtual machine and overlay visibility.
    ///
    /// - Parameters:
    ///   - virtualMachine: The VM to display, or `nil` to clear.
    ///   - isPaused: Whether the pause overlay should be visible.
    ///   - transitionText: If non-nil, shows the transition overlay with this label (e.g. "Suspending…").
    func update(virtualMachine: VZVirtualMachine?, isPaused: Bool, transitionText: String?) {
        if machineView.virtualMachine !== virtualMachine {
            machineView.virtualMachine = virtualMachine
        }
        setOverlay(pauseOverlay, visible: isPaused, flag: &pauseVisible)
        setOverlay(transitionOverlay, visible: transitionText != nil, flag: &transitionVisible)
        if let transitionText {
            transitionLabel.stringValue = transitionText
        }
    }

    // MARK: - Overlay Animation

    private func setOverlay(_ overlay: NSVisualEffectView, visible: Bool, flag: inout Bool) {
        guard flag != visible else { return }
        flag = visible

        if visible { overlay.isHidden = false }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlay.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak overlay] in
            MainActor.assumeIsolated {
                if !visible { overlay?.isHidden = true }
            }
        }
    }

    @objc private func resumeTapped() {
        onResume?()
    }

    // MARK: - Overlay Factory Methods

    private static func makePauseOverlay() -> (NSVisualEffectView, NSButton) {
        let effect = makeOverlayEffect()

        let image = NSImage.systemSymbol("play.circle.fill", accessibilityDescription: "Resume")
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imageScaling = .scaleNone
        button.image = button.image?.withSymbolConfiguration(
            .init(pointSize: 52, weight: .regular)
        )
        button.contentTintColor = .white
        button.shadow = makeShadow(blurRadius: 8)

        let label = makeLabel("Paused")

        let stack = makeOverlayStack(arrangedSubviews: [button, label])
        effect.addSubview(stack)
        centerStack(stack, in: effect)

        return (effect, button)
    }

    private static func makeTransitionOverlay() -> (NSVisualEffectView, NSTextField) {
        let effect = makeOverlayEffect()

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.startAnimation(nil)

        let label = makeLabel("Restoring…")

        let stack = makeOverlayStack(arrangedSubviews: [spinner, label])
        effect.addSubview(stack)
        centerStack(stack, in: effect)

        return (effect, label)
    }

    private static func makeOverlayEffect() -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .fullScreenUI
        effect.blendingMode = .withinWindow
        effect.state = .active
        return effect
    }

    private static func makeOverlayStack(arrangedSubviews: [NSView]) -> NSStackView {
        let stack = NSStackView(views: arrangedSubviews)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func centerStack(_ stack: NSStackView, in parent: NSView) {
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: parent.centerYAnchor),
        ])
    }

    private static func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .title2)
        label.textColor = .white
        label.alignment = .center
        label.shadow = makeShadow(blurRadius: 4)
        return label
    }

    private static func makeShadow(blurRadius: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = blurRadius
        shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        return shadow
    }
}
