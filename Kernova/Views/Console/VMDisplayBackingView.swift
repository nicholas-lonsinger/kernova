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
    ///
    /// `stagedIn` is the directory a promise drag's files were written into,
    /// which the receiver owns once it takes the drop — the guest pulls from it
    /// long after the drag is over.
    var onDropFiles: (_ urls: [URL], _ stagedIn: URL?) -> Bool = { _, _ in false }

    /// Reports a drag this display took that produced no file to send — a file
    /// promise whose source failed to write it.
    ///
    /// The drag is over by then, so this is the only surface left to say so.
    var onDropUnreadable: () -> Void = {}

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

    private static let logger = Logger(subsystem: "app.kernova", category: "VMDisplayBackingView")

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
            registerForDraggedTypes(Self.draggedTypes)
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
        verdict(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        verdict(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showRejectCursor(false)
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
    private func dragOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        guard dropAvailability() == .available, carriesFiles(sender.draggingPasteboard) else {
            return []
        }
        return .copy
    }

    /// Whether a pasteboard holds anything a drop can send: files, or promises of
    /// files.
    private func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLReadingOptions)
            || promiseSource.carriesPromises(pasteboard)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Re-checked here rather than trusted from `draggingUpdated`: the guest
        // agent can go away between the last pointer move and the release.
        guard dropAvailability() == .available else { return false }
        let pasteboard = sender.draggingPasteboard
        let urls = Self.fileURLs(on: pasteboard)
        let receivers = promiseSource.receivers(pasteboard)
        guard !receivers.isEmpty else {
            guard !urls.isEmpty else { return false }
            return onDropFiles(urls, nil)
        }
        receivePromises(receivers, alongside: urls)
        // The promised files are written asynchronously, so the drag ends taken
        // and the offer follows once they land.
        return true
    }

    /// The concrete file URLs a drag carries, leaving out every item a file
    /// promise already speaks for.
    ///
    /// Read item by item rather than off the pasteboard as a whole because one
    /// dragged item can advertise both: a Photos asset offers a promise of the
    /// original beside a URL into the library's own derivatives — the same
    /// picture, smaller — and reading both sends one dragged item to the guest
    /// as two files. The promise wins: it is what the source means to hand over.
    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard Set(item.types).isDisjoint(with: promisedItemTypes),
                let string = item.string(forType: .fileURL),
                let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
    }

    /// Materializes `receivers` into a directory of this drop's own, then offers
    /// them together with the concrete `urls` the same drag carried.
    ///
    /// One drop, not two: a mixed drag is one gesture, and one offer gives it one
    /// readout to report and cancel through.
    private func receivePromises(
        _ receivers: [any DisplayDropPromiseReceiving], alongside urls: [URL]
    ) {
        guard let directory = DropPromiseStaging.makeDropDirectory() else {
            // Nothing will ever be written, so the drag the display just took has
            // to answer for itself here.
            onDropUnreadable()
            return
        }
        let collection = PromiseCollection(receiverCount: receivers.count, alongside: urls)
        for (index, receiver) in receivers.enumerated() {
            // `OperationQueue.main`: the reader only tallies what landed, and the
            // promise's own writing already happens off it.
            receiver.receivePromisedFiles(
                atDestination: directory, options: [:], operationQueue: .main
            ) { [weak self, weak receiver] url, error in
                // Tallied before `self` is consulted, so a display torn down
                // mid-write still reaches quiescence: the count is what says
                // nothing more will be written into this directory.
                //
                // `weak receiver`: this closure is the receiver's to hold, so
                // holding it back would keep the pair alive on each other. One
                // already gone owes whatever it last named.
                let outcome = collection.received(
                    url, error: error, from: index, naming: receiver?.fileNames.count)
                guard let self, let outcome else {
                    // A failure settles the drag while its other promises are
                    // still writing into this directory; the last of them to
                    // report is what says nothing more will be.
                    if collection.canReleaseStaging { DropPromiseStaging.release(directory) }
                    return
                }
                self.finishPromiseDrop(outcome, stagedIn: directory, in: collection)
            }
        }
    }

    /// Offers a promise drag's whole set, or answers for one that never
    /// completed.
    ///
    /// The staging directory goes with the drop the service takes on, which
    /// frees it when that drop settles; every other path frees it here, once
    /// ``PromiseCollection/canReleaseStaging`` says no promise is still writing
    /// into it and no drop has taken it over.
    private func finishPromiseDrop(
        _ outcome: PromiseCollection.Outcome, stagedIn directory: URL,
        in collection: PromiseCollection
    ) {
        switch outcome {
        case .ready(let files):
            guard onDropFiles(files, directory) else {
                // The VM stopped taking drops while the source was still
                // writing; the service that would report it is already gone.
                Self.logger.warning("A promise drag's files landed after the VM stopped taking them")
                DropPromiseStaging.release(directory)
                return
            }
            collection.stagingWasTakenOver()
        case .failed(let error):
            Self.logger.warning(
                "A dropped file promise was never written: \(error?.localizedDescription ?? "no file", privacy: .public)"
            )
            if collection.canReleaseStaging { DropPromiseStaging.release(directory) }
            onDropUnreadable()
        }
    }

    /// Tallies what one drag's promises write, so the drop is offered exactly
    /// once — with the concrete files the same drag carried alongside them.
    ///
    /// How many files a receiver owes is asked of it again at every callback
    /// rather than totalled when the drag is taken: `NSFilePromiseReceiver`
    /// populates `fileNames` as its files are received, so a source that names
    /// nothing up front — a Photos asset does — still owes the one file its
    /// presence on the pasteboard promises.
    @MainActor
    private final class PromiseCollection {
        /// What the drag became once it stopped waiting.
        enum Outcome {
            /// Every promise was written; these are the drag's files, the
            /// promised ones last.
            case ready([URL])
            /// A promise's source failed to write, so the set is never whole.
            case failed((any Error)?)
        }

        /// How many files each receiver owes, by its index in the drag's
        /// receivers.
        ///
        /// The most it has ever named, so a count that reads short mid-write
        /// cannot shrink what is still owed — and never fewer than one: a
        /// receiver that names nothing is on the pasteboard because it promises
        /// something, and its names appear only as that something lands.
        private var owed: [Int]
        /// How many files each receiver has reported, by the same index.
        private var reported: [Int]
        private var files: [URL]
        private var isSettled = false
        private var isStagingTakenOver = false

        /// Whether every promise has reported, so nothing more will be written
        /// into the drag's staging directory.
        ///
        /// A latch, so a source that reports more often than its names account
        /// for cannot un-latch it and strand the directory.
        private(set) var isQuiesced = false

        init(receiverCount: Int, alongside files: [URL]) {
            self.owed = Array(repeating: 1, count: receiverCount)
            self.reported = Array(repeating: 0, count: receiverCount)
            self.files = files
        }

        /// Whether the drag's staging directory is still the display's to free:
        /// nothing more will be written into it, and no drop has taken it on.
        var canReleaseStaging: Bool { isQuiesced && !isStagingTakenOver }

        /// Records that a drop took the staging directory on, so a promise that
        /// reports after the drop was offered cannot free what the guest is
        /// still pulling from.
        func stagingWasTakenOver() { isStagingTakenOver = true }

        /// Records one promise's result — `naming` is how many files its
        /// receiver names as of this callback — returning the outcome when this
        /// is what settled the drag and `nil` while it is still waiting.
        func received(
            _ url: URL, error: (any Error)?, from index: Int, naming names: Int?
        ) -> Outcome? {
            reported[index] += 1
            owed[index] = max(owed[index], names ?? 0)
            isQuiesced = isQuiesced || isComplete
            guard !isSettled else { return nil }
            guard error == nil else {
                isSettled = true
                return .failed(error)
            }
            files.append(url)
            guard isComplete else { return nil }
            isSettled = true
            return .ready(files)
        }

        /// Whether every receiver has reported every file it owes.
        private var isComplete: Bool {
            zip(reported, owed).allSatisfy { $0 >= $1 }
        }
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
