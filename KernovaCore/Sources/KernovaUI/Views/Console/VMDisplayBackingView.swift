import Cocoa
import KernovaCore
import KernovaKit
import KernovaLogging
import KernovaVirtualization
import Virtualization

/// The `VZVirtualMachineView` properties Kernova drives from a VM's settings,
/// carried together so both display hosts write the same set.
struct VMDisplayViewSettings: Equatable {
    /// Whether the guest reconfigures its display to follow the view as it is
    /// resized.
    var automaticallyReconfiguresDisplay: Bool
    /// Whether system hot keys reach the guest instead of the host.
    var capturesSystemKeys: Bool
}

/// Pure AppKit view containing the VM's screen (``VMDisplayMachineView``) with built-in pause and
/// transition overlays, and the drag destination files dropped on the display reach.
///
/// Used directly as `window.contentView` in the detached display window, and layered on top of
/// the inline detail content by `DetailContainerViewController`.
@MainActor
final class VMDisplayBackingView: NSView {
    private(set) var machineView = VMDisplayMachineView()

    /// Called when the user taps the resume button on the pause overlay.
    var onResume: (() -> Void)?

    /// The VM this display moves files to and from, or `nil` when it has none.
    ///
    /// Resolved at every drag event rather than cached, so a drag that outlives
    /// the guest agent's connection stops being accepted mid-gesture. Setting it
    /// starts the display's own observation of the host's availability, which
    /// registers and unregisters it as a drag destination.
    var transferHost: () -> (any VMDisplayTransferHosting)? = { nil } {
        didSet { observeDropAvailability() }
    }

    /// Keeps the drag registration in step with ``transferHost``'s
    /// availability.
    private var dropAvailabilityObservation: ObservationLoop?

    /// How the display finds the file promises a drag carries.
    ///
    /// Injected so a test can stand in for a promise source: a promise cannot be
    /// written onto a pasteboard from the receiving side.
    var promiseSource = DisplayDropPromiseSource.pasteboard

    /// Shows or hides the "not allowed" cursor over a drag this display refuses.
    ///
    /// Injected so a test can see the pushes and pops pair up without a live
    /// cursor stack.
    var applyRejectCursor: (Bool) -> Void = { showing in
        if showing {
            NSCursor.operationNotAllowed.push()
        } else {
            NSCursor.pop()
        }
    }

    /// Whether `registerForDraggedTypes` is currently in effect, so
    /// ``applyDropRegistration()`` can be called on every observation tick
    /// without churning AppKit's registration.
    private var isDropRegistered = false

    /// Whether the reject cursor is pushed, so pushes and pops stay paired
    /// across every way a drag can leave or end.
    private var rejectCursorShowing = false

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMDisplayBackingView")

    /// The reading options a concrete file URL takes — a Finder drag's own form.
    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]

    /// Every type a display drop takes: concrete file URLs, plus the promise
    /// types a source that writes its files on demand advertises — Photos, a
    /// Mail attachment, an image dragged out of a browser.
    private static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + Self.promisedItemTypes
    }

    /// The types that mark a dragged item as one a file promise speaks for.
    private static let promisedItemTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    /// What was last written to `machineView`, so ``apply(_:)`` touches a
    /// framework property only when its value actually changes — a distinction
    /// `automaticallyReconfiguresDisplay` makes: `VZVirtualMachineView.h` says
    /// setting it on a second view targeting the same display turns it off on
    /// the first.
    ///
    /// `nil` until the first pass, which is what lets the view start from VZ's
    /// own defaults instead of a copy of them kept here.
    private var appliedSettings: VMDisplayViewSettings?

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

        machineView.transferHost = { [weak self] in self?.transferHost() }
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
    ///   - settings: The framework properties this VM's display should carry now.
    func update(
        display: VMDisplayHandle?, isPaused: Bool, transitionText: String?,
        settings: VMDisplayViewSettings
    ) {
        // Before the attach: VZ reconfigures the guest display as the VM is
        // assigned, so a stale flag reconfigures a VM the user opted out of.
        apply(settings)
        show(display: display, isPaused: isPaused, transitionText: transitionText)
    }

    /// Clears the displayed VM and its overlays on a view about to be discarded.
    ///
    /// Leaves the applied settings where they are: with no VM attached there is
    /// nothing left for them to act on.
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

    /// Writes `settings` to the machine view, on a view that may be hidden or
    /// showing no VM.
    func apply(_ settings: VMDisplayViewSettings) {
        guard settings != appliedSettings else { return }
        if settings.automaticallyReconfiguresDisplay
            != appliedSettings?.automaticallyReconfiguresDisplay
        {
            machineView.automaticallyReconfiguresDisplay =
                settings.automaticallyReconfiguresDisplay
        }
        if settings.capturesSystemKeys != appliedSettings?.capturesSystemKeys {
            machineView.capturesSystemKeys = settings.capturesSystemKeys
        }
        appliedSettings = settings
    }

    // MARK: - File Drop

    /// Registers (or unregisters) the display as a drag destination to match the
    /// VM's current availability.
    ///
    /// Registration is what separates the two refusals the issue asks for: a VM
    /// that has never run the agent is *not* a destination, so a drag over it is
    /// as if Kernova weren't there, while a registered-but-disconnected one takes
    /// part and returns an empty operation. Idempotent — the display's own
    /// observation calls it on every change to the host's availability.
    func applyDropRegistration() {
        let shouldRegister = availability != .none
        guard shouldRegister != isDropRegistered else { return }
        isDropRegistered = shouldRegister
        if shouldRegister {
            registerForDraggedTypes(Self.draggedTypes)
            // A `VZVirtualMachineView` covering this view would take the drag
            // first if it registered types of its own. It does not today, and
            // this is the line that says so if that ever changes.
            if !machineView.registeredDraggedTypes.isEmpty {
                Self.logger.log(
                    .fault,
                    "VZVirtualMachineView registers dragged types — display drops will not reach Kernova"
                )
                assertionFailure("VZVirtualMachineView registers dragged types")
            }
        } else {
            unregisterDraggedTypes()
        }
    }

    /// Whether the host takes drops now; `.none` with no host.
    private var availability: DisplayDropAvailability {
        transferHost()?.displayDropAvailability ?? .none
    }

    /// Registers the display to match its host now, and again whenever what the
    /// host's availability reads changes.
    private func observeDropAvailability() {
        applyDropRegistration()
        dropAvailabilityObservation = observeRecurring(
            track: { [weak self] in _ = self?.availability },
            apply: { [weak self] in self?.applyDropRegistration() })
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        verdict(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        verdict(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showRejectCursor(false)
        if let sender, let take = ownDragOut(sender) { take.hostSessionLeft(machineView) }
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        showRejectCursor(false)
    }

    /// This drag's operation, with the pointer told the same thing.
    ///
    /// Recomputed on every drag event rather than latched at entry, so a VM that
    /// pauses — or an agent that goes away — mid-drag flips the cursor on the
    /// next pointer move, and one that becomes reachable clears it.
    private func verdict(for sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = dragOperation(for: sender)
        showRejectCursor(operation.isEmpty)
        return operation
    }

    /// Puts the standard "not allowed" cursor under the pointer while this
    /// display is refusing, which is the only thing that distinguishes a refusal
    /// from a destination that simply takes no badge.
    private func showRejectCursor(_ showing: Bool) {
        guard showing != rejectCursorShowing else { return }
        rejectCursorShowing = showing
        applyRejectCursor(showing)
    }

    /// `.copy` when this drag can be sent to the guest, else the empty operation
    /// AppKit renders as "no" — no accept badge, and a release springs back.
    ///
    /// A drag out of this same VM is the guest's own drag, still live in the
    /// guest: its take moves the guest pointer with it and says whether a drop
    /// here goes to the guest. Its promises are never read — they would be
    /// written by pulling from the guest that is to receive them.
    private func dragOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        if let take = ownDragOut(sender) {
            return take.hostSession(over: machineView, at: machineLocation(of: sender)) ? .copy : []
        }
        guard acceptsDrop(of: sender), carriesFiles(sender.draggingPasteboard) else {
            return []
        }
        return .copy
    }

    /// The take carrying `sender`, when it is a drag out of this same VM.
    private func ownDragOut(_ sender: any NSDraggingInfo) -> (any GuestDragTaking)? {
        guard let source = sender.draggingSource as? DisplayDragOutSource,
            let host = transferHost(), source.vmID == host.id
        else { return nil }
        return source.take
    }

    /// Where `sender` is, in the machine view's coordinates.
    private func machineLocation(of sender: any NSDraggingInfo) -> CGPoint {
        machineView.convert(sender.draggingLocation, from: nil)
    }

    /// Whether the guest can take a drop now from `sender`, a drag from
    /// anywhere but this same VM.
    private func acceptsDrop(of sender: any NSDraggingInfo) -> Bool {
        guard let host = transferHost(), host.displayDropAvailability == .available else {
            return false
        }
        if let source = sender.draggingSource as? DisplayDragOutSource, source.vmID == host.id {
            return false
        }
        return true
    }

    /// Whether a pasteboard holds anything a drop can send: files, or promises of
    /// files.
    private func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLReadingOptions)
            || promiseSource.carriesPromises(pasteboard)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let take = ownDragOut(sender) {
            return take.hostSessionDropped(on: machineView, at: machineLocation(of: sender))
        }
        // Re-checked here rather than trusted from `draggingUpdated`: the guest
        // agent can go away between the last pointer move and the release.
        guard acceptsDrop(of: sender), let host = transferHost() else { return false }
        let pasteboard = sender.draggingPasteboard
        let receivers = promiseSource.receivers(pasteboard)
        if !receivers.isEmpty {
            guard DisplayDragOutSource.nameItems(of: sender) else { return false }
        }
        return host.dropOnGuest(pasteboard, promises: receivers)
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
