import Cocoa
import KernovaProtocol
import os

/// Pure AppKit view controller for the clipboard sharing window content.
///
/// The content area renders the buffer per `ClipboardPreviewPolicy`: an
/// editable `NSTextView` for text (and the empty buffer), an image preview,
/// or a generic per-representation summary. Below it, a command bar offers
/// explicit host-pasteboard transfer ("Paste from Mac" / "Copy to Mac",
/// also reachable through the responder chain as `paste:`/`copy:` outside
/// the editor) plus a content-type indicator that doubles as the transient
/// status surface; drag-and-drop into the window feeds the same intake path
/// as the Paste button. The bottom status bar shows the guest agent
/// connection state and surfaces the install/update affordance for macOS
/// guests (Linux guests use `spice-vdagent` from their package manager —
/// the affordance is hidden for them).
///
/// Conflict policy is last-writer-wins: every keystroke pushes the edit into
/// `clipboardService.clipboardContent`, so "unsent edits" are model state and
/// a guest update that lands mid-edit is simply a newer writer. Echo
/// suppression is digest-based — `lastAppliedDigest` is set *before* writing
/// the model, so the resulting observation pass recognizes the content as
/// already displayed instead of re-applying it (this replaces the fragile
/// reentrancy flag the previous implementation used).
@MainActor
final class ClipboardContentViewController: NSViewController, NSTextViewDelegate,
    NSUserInterfaceValidations
{
    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardContentViewController")

    private let instance: VMInstance
    private weak var viewModel: VMLibraryViewModel?

    // MARK: - Views

    private let dropContainer = ClipboardDropContainerView()
    private let textView: ClipboardEditorTextView
    private let scrollView: NSScrollView
    private let richTextPreview = ClipboardRichTextPreviewView()
    private let imagePreview = ClipboardImagePreviewView()
    private let filePreview = ClipboardFilePreviewView()
    private let summaryView = ClipboardSummaryView()
    private let commandBar = ClipboardCommandBarView()

    /// Every content view stacked in the content area; exactly one is visible.
    /// `scrollView` (the editable plain-text editor) is first — the default.
    private var contentViews: [NSView] {
        [scrollView, richTextPreview, imagePreview, filePreview, summaryView]
    }
    private let statusCircle: NSView
    private let statusLabel: NSTextField
    private let actionButton: NSButton

    // MARK: - State

    /// Digest of the content currently rendered in the content area.
    ///
    /// When the observed model digest matches, the content rebuild is
    /// skipped — both for cheap no-op passes and for the echo of our own
    /// writes.
    private var lastAppliedDigest: Data?

    /// Last transfer issue already shown as a transient.
    ///
    /// Tracked so re-observation doesn't re-show it; compared by value
    /// (`date` is the re-fire identity).
    private var lastShownIssue: ClipboardTransferIssue?

    private var serviceObservation: ObservationLoop?

    /// Queue handed to `NSFilePromiseReceiver` for writing promised files;
    /// the completion hops back to the main actor before touching state.
    private let promiseQueue = OperationQueue()

    /// Label for the host-side clipboard staging root.
    ///
    /// Shared so `AppDelegate`'s launch-time orphan sweep targets the same temp
    /// directory this controller stages into (the staging never sweeps on
    /// window close — that would invalidate a just-copied file URL still on the
    /// pasteboard — so orphans are reclaimed at launch instead, mirroring how
    /// the guest agent sweeps on start).
    static let stagingLabel = "host"

    /// Materializes file payloads to local temp files for "Copy to Mac" so a
    /// Finder paste creates the file (bounded to one payload; superseded each
    /// copy).
    private let staging = ClipboardFileStaging(label: ClipboardContentViewController.stagingLabel)

    /// First-file-wins gate shared by one promise receipt's per-file
    /// completions (the buffer models a single pasteboard item).
    @MainActor
    private final class PromiseFirstFileGate {
        var taken = false
    }

    init(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance
        self.viewModel = viewModel

        let textView = ClipboardEditorTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        self.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        self.scrollView = scrollView

        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.cornerRadius = 4
        circle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 8),
            circle.heightAnchor.constraint(equalToConstant: 8),
        ])
        self.statusCircle = circle

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.statusLabel = label

        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.isHidden = true
        self.actionButton = button

        super.init(nibName: nil, bundle: nil)

        textView.delegate = self
        // An editable text view would otherwise swallow a file/image/screenshot
        // drop and insert the file's path as text — divert those to the same
        // image-aware intake as a drop on the container.
        textView.onDivertedDrop = { [weak self] in self?.handleDrop($0) ?? false }
        button.target = self
        button.action = #selector(actionButtonClicked(_:))
        commandBar.pasteButton.target = self
        commandBar.pasteButton.action = #selector(pasteFromMac(_:))
        commandBar.copyButton.target = self
        commandBar.copyButton.action = #selector(copyToMac(_:))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = dropContainer
        container.canAcceptDrop = { [weak self] in
            self?.instance.clipboardService != nil
        }
        container.onDrop = { [weak self] draggingInfo in
            self?.handleDrop(draggingInfo) ?? false
        }

        // All content views are installed once and toggled via isHidden — no
        // add/remove churn when the preview mode changes. The editor leads
        // (the default visible view); the rest start hidden.
        for contentView in contentViews {
            contentView.translatesAutoresizingMaskIntoConstraints = false
            contentView.isHidden = contentView !== scrollView
            container.addSubview(contentView)
        }

        let commandDivider = NSBox()
        commandDivider.boxType = .separator
        commandDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(commandDivider)

        commandBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(commandBar)

        let statusDivider = NSBox()
        statusDivider.boxType = .separator
        statusDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusDivider)

        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBar)

        var constraints: [NSLayoutConstraint] = []
        for contentView in contentViews {
            constraints += [
                contentView.topAnchor.constraint(equalTo: container.topAnchor),
                contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: commandDivider.topAnchor),
            ]
        }
        constraints += [
            commandDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            commandDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            commandBar.topAnchor.constraint(equalTo: commandDivider.bottomAnchor),
            commandBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            statusDivider.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            statusDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            statusBar.topAnchor.constraint(equalTo: statusDivider.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)

        // Lower content hugging so the content area yields space to the bars.
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
        observeServiceChanges()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let service = instance.clipboardService else {
            Self.logger.warning(
                "Clipboard edit ignored — clipboardService is nil for VM '\(self.instance.name, privacy: .public)'")
            return
        }
        let edited = ClipboardContent(text: textView.string)
        // Pre-set the digest so the observation pass triggered by the model
        // write recognizes the content as already displayed (the editor IS
        // the source) and doesn't rebuild the view out from under the user.
        lastAppliedDigest = edited.digest
        service.clipboardContent = edited
        commandBar.setIndicatorText(ClipboardContentDescriber.indicatorText(for: edited))
        commandBar.copyButton.isEnabled = !edited.isEmpty
    }

    // MARK: - Observation

    private func observeServiceChanges() {
        serviceObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                // Read each property so observation re-fires when any of them
                // transitions: clipboardService (nil → non-nil on connect),
                // vsockControlService (drives agentStatus for macOS guests),
                // and the per-property fields the UI mirrors.
                let clipService = self.instance.clipboardService
                _ = clipService?.clipboardContent
                _ = clipService?.isConnected
                _ = clipService?.lastTransferIssue
                _ = self.instance.vsockControlService?.agentStatus
                _ = self.instance.agentStatus
            },
            apply: { [weak self] in
                self?.updateUI()
            }
        )
    }

    private func updateUI() {
        let service = instance.clipboardService
        let status = instance.agentStatus
        let canInstallKernovaAgent = instance.configuration.guestOS == .macOS

        textView.isEditable = service != nil
        commandBar.pasteButton.isEnabled = service != nil
        commandBar.copyButton.isEnabled = service != nil && !(service?.clipboardContent.isEmpty ?? true)

        if let service {
            let content = service.clipboardContent
            if content.digest != lastAppliedDigest {
                lastAppliedDigest = content.digest
                apply(content: content)
                commandBar.setIndicatorText(ClipboardContentDescriber.indicatorText(for: content))
            }
            if let issue = service.lastTransferIssue, issue != lastShownIssue {
                lastShownIssue = issue
                commandBar.showTransientMessage(message(for: issue), style: .error)
            }
        }

        applyStatus(status, canInstallKernovaAgent: canInstallKernovaAgent)
    }

    // MARK: - Content rendering

    private func apply(content: ClipboardContent) {
        switch ClipboardPreviewPolicy.mode(for: content) {
        case .empty:
            showTextEditor(text: "")
        case .text(let text):
            showTextEditor(text: text)
        case .richText(let data, let uti):
            if richTextPreview.configure(data: data, uti: uti) {
                show(contentView: richTextPreview)
            } else {
                // Undecodable RTF degrades to the summary.
                summaryView.configure(content: content)
                show(contentView: summaryView)
            }
        case .image(let data, let uti):
            if imagePreview.configure(data: data, uti: uti) {
                show(contentView: imagePreview)
            } else {
                // Undecodable image bytes degrade to the summary.
                summaryView.configure(content: content)
                show(contentView: summaryView)
            }
        case .file(let filename, let uti, let byteCount):
            filePreview.configure(filename: filename, uti: uti, byteCount: byteCount)
            show(contentView: filePreview)
        case .summary:
            summaryView.configure(content: content)
            show(contentView: summaryView)
        }
    }

    private func showTextEditor(text: String) {
        if textView.string != text {
            // Replacing the buffer invalidates the editor's undo history —
            // undo must not resurrect superseded clipboard states.
            textView.breakUndoCoalescing()
            textView.string = text
            textView.undoManager?.removeAllActions()
        }
        show(contentView: scrollView)
    }

    private func show(contentView: NSView) {
        // Move focus off the editor before hiding it; a hidden first
        // responder leaves the window without a sane key view.
        if contentView !== scrollView, view.window?.firstResponder === textView {
            view.window?.makeFirstResponder(dropContainer)
        }
        for view in contentViews {
            view.isHidden = view !== contentView
        }
    }

    private func message(for issue: ClipboardTransferIssue) -> String {
        switch issue.kind {
        case .contentTooLarge(let byteCount, let limit):
            return
                "Content is too large to send (\(DataFormatters.formatBytes(UInt64(byteCount))) — limit \(DataFormatters.formatBytes(UInt64(limit))))"
        case .peerReportedError(let code, _):
            switch code {
            case "clipboard.transfer.too.large":
                return "The guest rejected the transfer as too large"
            case "clipboard.format.unavailable":
                return "The guest couldn't provide the requested format"
            default:
                return "Clipboard transfer failed on the guest side"
            }
        }
    }

    // MARK: - Actions

    @objc private func pasteFromMac(_ sender: Any?) {
        _ = takeIn(pasteboard: .general)
    }

    @objc private func copyToMac(_ sender: Any?) {
        guard let service = instance.clipboardService else { return }
        let content = service.clipboardContent
        guard !content.isEmpty else { return }

        let item = NSPasteboardItem()
        // Non-file content and image file payloads are inlined (Notes shows
        // them in place); a non-image file payload is carried only as the
        // staged file URL below, so it attaches as a file rather than inserting
        // its contents. See `ClipboardContent.Representation.shouldInlineOnPasteboard`.
        for representation in content.representations where representation.shouldInlineOnPasteboard {
            item.setData(
                representation.data,
                forType: NSPasteboard.PasteboardType(rawValue: representation.uti)
            )
        }
        // For file payloads, stage a local temp file and offer its URL so a
        // Finder paste creates the file (alongside any inline image data).
        for staged in staging.stage(content.representations) {
            item.setData(Data(staged.url.absoluteString.utf8), forType: .fileURL)
        }
        // A non-image file payload contributes no inline data; if staging also
        // failed, the item is empty. Don't clear the Mac clipboard to write
        // nothing — surface the failure instead.
        guard !item.types.isEmpty else {
            commandBar.showTransientMessage("Couldn't prepare the clipboard content to copy", style: .error)
            Self.logger.error("copyToMac produced no pasteboard representations (staging failed)")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([item]) {
            commandBar.showTransientMessage("Copied to Mac clipboard", style: .info)
            Self.logger.info(
                "Copied clipboard buffer to host pasteboard (\(content.representations.count, privacy: .public) reps)"
            )
        } else {
            commandBar.showTransientMessage("Couldn't write to the Mac clipboard", style: .error)
            Self.logger.error("NSPasteboard.writeObjects failed for clipboard buffer")
        }
    }

    /// Shared intake for the Paste button, responder-chain `paste:`, and drag-and-drop.
    ///
    /// Paste/drop are complete gestures — the content is sent to the guest
    /// immediately, unlike typed edits which send on window blur.
    private func takeIn(pasteboard: NSPasteboard) -> Bool {
        guard let service = instance.clipboardService else { return false }
        return apply(
            intake: ClipboardPasteboardIntake.read(
                from: pasteboard,
                allowsBinary: service.supportsBinaryRepresentations
            )
        )
    }

    /// Commits an intake result to the buffer (and the guest) or surfaces
    /// the rejection.
    private func apply(intake: ClipboardIntakeResult) -> Bool {
        guard let service = instance.clipboardService else { return false }

        switch intake {
        case .content(let content, let note):
            service.clipboardContent = content
            service.grabIfChanged()
            if let note {
                commandBar.showTransientMessage(note, style: .warning)
            }
            Self.logger.info(
                "Took in pasteboard content (\(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
            )
            return true
        case .rejected(let message):
            commandBar.showTransientMessage(message, style: .warning)
            Self.logger.info("Pasteboard intake rejected: \(message, privacy: .public)")
            return false
        }
    }

    // MARK: - Drag-and-drop

    /// Routes a performed drop, image-first, so a dragged screenshot shows the
    /// image like other Mac apps.
    ///
    /// Synchronous intake (`read(from:)`) handles inline image data, a
    /// concrete-or-promised file already on disk (incl. the floating
    /// screenshot thumbnail, whose temp file screencaptureui has already
    /// written), and plain/rich text — and never surfaces a path string for a
    /// file/promise drag. Only when nothing usable resolves synchronously, and
    /// a modern file promise is present (Photos, browsers, or a screenshot
    /// whose file isn't on disk yet), is the file received asynchronously.
    private func handleDrop(_ draggingInfo: NSDraggingInfo) -> Bool {
        guard let service = instance.clipboardService else { return false }
        let pasteboard = draggingInfo.draggingPasteboard

        Self.logger.debug(
            "Clipboard drop types: \(pasteboard.pasteboardItems?.first?.types.map(\.rawValue).joined(separator: ", ") ?? "none", privacy: .public)"
        )

        let result = ClipboardPasteboardIntake.read(
            from: pasteboard,
            allowsBinary: service.supportsBinaryRepresentations
        )
        if case .content = result {
            return apply(intake: result)
        }

        // Nothing usable synchronously. Receive a modern file promise async.
        if let receiver = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])?
            .compactMap({ $0 as? NSFilePromiseReceiver }).first
        {
            receivePromisedFile(receiver)
            return true
        }
        // Surface the rejection (never a path string for a file/promise drag).
        return apply(intake: result)
    }

    /// Receives a promised file into a scratch directory, runs it through
    /// the shared file intake, and cleans the scratch copy up (the buffer
    /// keeps the bytes, not the file).
    private func receivePromisedFile(_ receiver: NSFilePromiseReceiver) {
        guard let service = instance.clipboardService else { return }
        let allowsBinary = service.supportsBinaryRepresentations

        commandBar.showTransientMessage("Receiving dropped file…", style: .info)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaClipboardDrops-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            commandBar.showTransientMessage("Couldn't receive the dropped file", style: .error)
            Self.logger.error(
                "Failed to create promise scratch directory: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // The reader block runs once per promised file. The buffer models a
        // single item, so the first successfully received file wins; the
        // gate is @MainActor state shared by the per-file completions.
        let firstFileGate = PromiseFirstFileGate()

        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) {
            url, error in
            Task { @MainActor [weak self] in
                // Per-file cleanup happens even if the window closed before
                // the promise resolved (self gone). Removing the directory
                // is best-effort and only when it has drained — removeItem
                // on a directory is recursive and must not race files still
                // being written by a multi-file promise.
                defer {
                    try? FileManager.default.removeItem(at: url)
                    if let remaining = try? FileManager.default.contentsOfDirectory(atPath: destination.path),
                        remaining.isEmpty
                    {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
                guard let self else { return }
                if let error {
                    self.commandBar.showTransientMessage("Couldn't receive the dropped file", style: .error)
                    Self.logger.error(
                        "File promise receipt failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                guard !firstFileGate.taken else { return }
                firstFileGate.taken = true
                _ = self.apply(intake: ClipboardPasteboardIntake.read(fileAt: url, allowsBinary: allowsBinary))
            }
        }
    }

    // MARK: - Responder-chain edit actions

    // Cover image/summary/empty-unfocused modes; in text mode the focused
    // NSTextView handles Cmd+V/Cmd+C natively (and pasting an image with the
    // editor focused does nothing — the Paste button is the affordance).
    @objc func paste(_ sender: Any?) {
        _ = takeIn(pasteboard: .general)
    }

    @objc func copy(_ sender: Any?) {
        copyToMac(sender)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)):
            return instance.clipboardService != nil
        case #selector(copy(_:)):
            guard let service = instance.clipboardService else { return false }
            return !service.clipboardContent.isEmpty
        default:
            return true
        }
    }

    @objc private func actionButtonClicked(_: Any?) {
        viewModel?.mountGuestAgentInstaller(on: instance)
    }

    // MARK: - Agent status bar

    private func applyStatus(_ status: AgentStatus, canInstallKernovaAgent: Bool) {
        switch status {
        case .waiting:
            statusCircle.layer?.backgroundColor = StatusColor.inactive.cgColor
            statusLabel.stringValue = "Waiting for guest agent"
            actionButton.isHidden = !canInstallKernovaAgent
            actionButton.title = "Install Guest Agent…"
        case .outdated(let installed, let bundled):
            statusCircle.layer?.backgroundColor = StatusColor.warning.cgColor
            statusLabel.stringValue = "Update available (\(installed) → \(bundled))"
            actionButton.isHidden = !canInstallKernovaAgent
            actionButton.title = "Update Guest Agent…"
        case .connecting(let expected):
            // Live session for a previously-installed agent that hasn't
            // said Hello yet. No install/reinstall affordance — the agent
            // is expected to reconnect; the watchdog will surface
            // `.expectedMissing` if it doesn't.
            statusCircle.layer?.backgroundColor = StatusColor.inactive.cgColor
            statusLabel.stringValue = "Connecting (was \(expected))"
            actionButton.isHidden = true
        case .current(let version):
            statusCircle.layer?.backgroundColor = StatusColor.running.cgColor
            statusLabel.stringValue = "Connected (\(version))"
            actionButton.isHidden = true
        case .unresponsive(let version):
            statusCircle.layer?.backgroundColor = StatusColor.warning.cgColor
            statusLabel.stringValue = "Unresponsive (\(version))"
            actionButton.isHidden = true
        case .expectedMissing(let expected):
            statusCircle.layer?.backgroundColor = StatusColor.warning.cgColor
            statusLabel.stringValue = "Didn't reconnect (was \(expected))"
            actionButton.isHidden = !canInstallKernovaAgent
            actionButton.title = "Reinstall Guest Agent…"
        }
    }

    // MARK: - View Construction

    private func makeStatusBar() -> NSView {
        // Spacer needs an explicit low horizontal hugging priority to actually
        // expand inside the NSStackView. NSView's default hugging priority is
        // 250 — same as the label's — so without this, the stack view has no
        // signal to grow the spacer rather than the label, and the button
        // wouldn't reliably end up flush against the trailing edge.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [statusCircle, statusLabel, spacer, actionButton])
        stack.orientation = .horizontal
        stack.spacing = Spacing.small
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.alignment = .centerY

        return stack
    }
}
