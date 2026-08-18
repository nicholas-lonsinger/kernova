import Cocoa
import Virtualization
import os

/// Pure AppKit view containing a `VZVirtualMachineView` with built-in pause and transition overlays.
///
/// Used directly as `window.contentView` in the detached display window, and layered on top of
/// the inline detail content by `DetailContainerViewController`.
@MainActor
final class VMDisplayBackingView: NSView {
    private(set) var machineView: VZVirtualMachineView = {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        return view
    }()

    /// Called when the user taps the resume button on the pause overlay.
    var onResume: (() -> Void)?

    /// Whether this VM can take files dropped on its display right now.
    ///
    /// Read at every drag event rather than cached, so a drag that outlives the
    /// guest agent's connection stops being accepted mid-gesture.
    var dropAvailability: () -> DisplayDropAvailability = { .none }

    /// Sends dropped file URLs to the guest, reporting whether they were taken.
    var onDropFiles: ([URL]) -> Bool = { _ in false }

    /// Whether `registerForDraggedTypes` is currently in effect, so
    /// ``applyDropRegistration()`` can be called on every observation tick
    /// without churning AppKit's registration.
    private var isDropRegistered = false

    private static let logger = Logger(subsystem: "app.kernova", category: "VMDisplayBackingView")

    /// The only pasteboard reading options a display drop ever uses: concrete
    /// file URLs, never a file promise. A Finder drag carries these; a
    /// promise-only drag never enters, because `.fileURL` is the sole registered
    /// type.
    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]

    /// Mirrors `machineView.automaticallyReconfiguresDisplay`, so ``apply(automaticallyReconfiguresDisplay:)``
    /// writes the framework property only when it actually changes.
    private var automaticallyReconfiguresDisplay = true

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
    ///   - display: The session's display handle, or `nil` to clear.
    ///   - isPaused: Whether the pause overlay should be visible.
    ///   - transitionText: If non-nil, shows the transition overlay with this label (e.g. "Suspending…").
    ///   - automaticallyReconfiguresDisplay: Whether the guest display follows the view as it resizes.
    func update(
        display: VMDisplayHandle?, isPaused: Bool, transitionText: String?,
        automaticallyReconfiguresDisplay: Bool
    ) {
        // Before the attach: VZ reconfigures the guest display as the VM is
        // assigned, so a stale flag reconfigures a VM the user opted out of.
        apply(automaticallyReconfiguresDisplay: automaticallyReconfiguresDisplay)
        show(display: display, isPaused: isPaused, transitionText: transitionText)
    }

    /// Clears the displayed VM and its overlays on a view about to be discarded.
    ///
    /// Leaves `automaticallyReconfiguresDisplay` where it is: with no VM
    /// attached there is nothing left for it to reconfigure.
    func detach() {
        show(display: nil, isPaused: false, transitionText: nil)
    }

    private func show(
        display: VMDisplayHandle?, isPaused: Bool, transitionText: String?
    ) {
        if let display {
            display.attach(to: machineView)
        } else if machineView.virtualMachine != nil {
            VMDisplayHandle.detach(machineView)
        }
        setOverlay(pauseOverlay, visible: isPaused, flag: &pauseVisible)
        setOverlay(transitionOverlay, visible: transitionText != nil, flag: &transitionVisible)
        if let transitionText {
            transitionLabel.stringValue = transitionText
        }
    }

    /// Sets whether the guest display follows the view as it resizes, on a view
    /// that may be hidden or showing no VM.
    func apply(automaticallyReconfiguresDisplay: Bool) {
        guard self.automaticallyReconfiguresDisplay != automaticallyReconfiguresDisplay else {
            return
        }
        self.automaticallyReconfiguresDisplay = automaticallyReconfiguresDisplay
        machineView.automaticallyReconfiguresDisplay = automaticallyReconfiguresDisplay
    }

    // MARK: - File Drop

    /// Registers (or unregisters) the display as a drag destination to match the
    /// VM's current availability.
    ///
    /// Registration is what separates the two refusals the issue asks for: a VM
    /// that has never run the agent is *not* a destination, so a drag over it is
    /// as if Kernova weren't there, while a registered-but-disconnected one takes
    /// part and returns an empty operation. Idempotent — hosts call it on every
    /// observation tick.
    func applyDropRegistration() {
        let shouldRegister = dropAvailability() != .none
        guard shouldRegister != isDropRegistered else { return }
        isDropRegistered = shouldRegister
        if shouldRegister {
            registerForDraggedTypes([.fileURL])
            // A `VZVirtualMachineView` covering this view would take the drag
            // first if it registered types of its own. It does not today, and
            // this is the line that says so if that ever changes.
            if !machineView.registeredDraggedTypes.isEmpty {
                Self.logger.fault(
                    "VZVirtualMachineView registers dragged types — display drops will not reach Kernova"
                )
                assertionFailure("VZVirtualMachineView registers dragged types")
            }
        } else {
            unregisterDraggedTypes()
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    /// `.copy` when this drag can be sent to the guest, else the empty operation
    /// AppKit renders as "no" — no accept badge, and a release springs back.
    private func dragOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        guard dropAvailability() == .available,
            sender.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self], options: Self.fileURLReadingOptions)
        else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: Self.fileURLReadingOptions) as? [URL],
            !urls.isEmpty
        else { return false }
        // Re-checked here rather than trusted from `draggingUpdated`: the guest
        // agent can go away between the last pointer move and the release.
        guard dropAvailability() == .available else { return false }
        return onDropFiles(urls)
    }

    // MARK: - Overlay Animation

    private func setOverlay(_ overlay: NSVisualEffectView, visible: Bool, flag: inout Bool) {
        guard flag != visible else { return }
        flag = visible

        if visible { overlay.isHidden = false }

        // 0.25s rather than the standard fade: the pause/transition overlays are
        // large surfaces where a slightly slower dissolve reads better.
        animateFade(overlay, to: visible ? 1 : 0, duration: 0.25) { [weak overlay] in
            if !visible { overlay?.isHidden = true }
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
        stack.spacing = Spacing.medium
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
