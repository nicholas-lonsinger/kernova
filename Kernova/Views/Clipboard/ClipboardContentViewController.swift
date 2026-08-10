import Cocoa
import KernovaKit
import os

/// Pure AppKit view controller for the clipboard sharing window content.
///
/// Conflict policy is last-writer-wins: every keystroke pushes the edit into
/// `clipboardService.clipboardContent`, so a guest update landing mid-edit is
/// simply a newer writer. Echo suppression is digest-based — `lastAppliedDigest`
/// is set *before* writing the model, so the resulting observation pass
/// recognizes the content as already displayed instead of re-applying it.
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
    private let filesPreview = ClipboardFilesPreviewView()
    private let summaryView = ClipboardSummaryView()
    private let concealedPreview = ClipboardConcealedPreviewView()
    private let commandBar = ClipboardCommandBarView()
    private let passthroughBanner = ClipboardPassthroughBanner()
    private lazy var passthroughBannerCollapsed = passthroughBanner.heightAnchor.constraint(
        equalToConstant: 0)
    private lazy var commandBarCollapsed = commandBar.heightAnchor.constraint(equalToConstant: 0)
    /// Content-type indicator; doubles as the transient-status surface.
    private let indicatorView = ClipboardIndicatorView()

    private let transferProgressBar = NSProgressIndicator()
    private lazy var transferBarCollapsed = transferProgressBar.heightAnchor.constraint(
        equalToConstant: 0)

    /// Every content view stacked in the content area; exactly one is visible.
    private var contentViews: [NSView] {
        [
            scrollView, richTextPreview, imagePreview, filePreview, filesPreview, summaryView,
            concealedPreview,
        ]
    }
    private let statusCircle: NSView
    private let statusLabel: NSTextField
    private let actionButton: NSButton

    // MARK: - State

    /// Digest of the content currently rendered in the content area.
    ///
    /// A matching observed digest skips the rebuild — both for no-op passes and
    /// for the echo of our own writes.
    private var lastAppliedDigest: Data?

    /// Debounced off-actor commit of the editor buffer.
    ///
    /// `textDidChange` does only cheap, hash-free work per keystroke (CLIPBOARD.md
    /// §8) and schedules this. `editSeq` bumps per keystroke so an in-flight commit
    /// can tell it was superseded; `hasPendingEdit` records that a keystroke has
    /// not yet reached the model.
    private var editDebounceTask: Task<Void, Never>?
    private var editSeq: UInt64 = 0
    private var hasPendingEdit = false

    /// Whether the user authored the current buffer — the condition
    /// `flushAndAnnounceEdit` announces on.
    ///
    /// Cleared when an external update replaces the edit; **not** cleared by the
    /// announcement.
    private var hasUserEdit = false

    /// Quiet period before a keystroke burst commits off-actor.
    private let editDebounceInterval: Duration

    /// This VM's outstanding transfer problem, whichever of its clipboard
    /// services raised it — including one superseded by a reconnect, which still
    /// raises the failures of the pasteboard promises it published.
    ///
    /// Not `clipboardService`'s own record: the center's notice stands down for
    /// as long as this window is up, so a report this window skipped would reach
    /// no surface at all.
    private let issueCenter: ClipboardIssueCenter

    /// Last transfer issue already shown as a transient, so re-observation
    /// doesn't re-show it.
    private var lastShownIssue: ClipboardTransferIssue?

    private var serviceObservation: ObservationLoop?
    /// Drives only the bottom transfer bar, separate from `serviceObservation`.
    private var transferProgressObservation: ObservationLoop?

    /// Queue handed to `NSFilePromiseReceiver` for writing promised files.
    private let promiseQueue = OperationQueue()

    /// Writes the buffer to the host pasteboard for "Copy to Mac" (CLIPBOARD.md §4).
    ///
    /// In production the same per-VM instance is shared with the passthrough
    /// coordinator, so echo suppression sees a manual "Copy to Mac" too.
    private let publisher: HostClipboardPublisher

    /// The host pasteboard "Paste from Mac" reads from — `.general` in production.
    private let readPasteboard: NSPasteboard

    /// `true` while a "Copy to Mac" is materializing/writing.
    ///
    /// The async pull republishes `clipboardContent`, which re-fires the
    /// observation pass and would re-enable the Copy button mid-copy; this flag is
    /// the real re-entrancy guard, not the button's enabled state.
    private var isCopyingToMac = false

    /// First-file-wins gate shared by one promise receipt's per-file
    /// completions (the buffer models a single pasteboard item).
    @MainActor
    private final class PromiseFirstFileGate {
        var taken = false
    }

    init(
        instance: VMInstance, viewModel: VMLibraryViewModel,
        writePasteboard: any HostWritePasteboard = NSPasteboard.general,
        readPasteboard: NSPasteboard = .general,
        providerRegistry: LazyClipboardProviderRegistry = .shared,
        publisher: HostClipboardPublisher? = nil,
        issueCenter: ClipboardIssueCenter = .shared,
        editDebounceInterval: Duration = .milliseconds(200)
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.readPasteboard = readPasteboard
        self.issueCenter = issueCenter
        self.publisher =
            publisher
            ?? HostClipboardPublisher(
                writePasteboard: writePasteboard, providerRegistry: providerRegistry)
        self.editDebounceInterval = editDebounceInterval

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
        textView.textContainer?.size = NSSize(
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
        // An editable text view would otherwise swallow a file/image drop and
        // insert the file's path as text — divert those to the container's intake.
        textView.onDivertedDrop = { [weak self] in self?.handleDrop($0) ?? false }
        button.target = self
        button.action = #selector(actionButtonClicked(_:))
        commandBar.pasteButton.target = self
        commandBar.pasteButton.action = #selector(pasteFromMac(_:))
        commandBar.copyButton.target = self
        commandBar.copyButton.action = #selector(copyToMac(_:))
        commandBar.clearButton.target = self
        commandBar.clearButton.action = #selector(clearClipboard(_:))
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

        for contentView in contentViews {
            contentView.translatesAutoresizingMaskIntoConstraints = false
            contentView.isHidden = contentView !== scrollView
            container.addSubview(contentView)
        }

        passthroughBanner.translatesAutoresizingMaskIntoConstraints = false
        passthroughBanner.isHidden = true
        passthroughBanner.onTurnOff = { [weak self] in self?.disablePassthrough() }
        container.addSubview(passthroughBanner)

        commandBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(commandBar)

        let statusDivider = NSBox()
        statusDivider.boxType = .separator
        statusDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusDivider)

        transferProgressBar.style = .bar
        transferProgressBar.isIndeterminate = false
        transferProgressBar.minValue = 0
        transferProgressBar.maxValue = 1
        transferProgressBar.doubleValue = 0
        transferProgressBar.isHidden = true
        transferProgressBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(transferProgressBar)

        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBar)

        var constraints: [NSLayoutConstraint] = [
            passthroughBanner.topAnchor.constraint(equalTo: container.topAnchor),
            passthroughBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            passthroughBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            passthroughBannerCollapsed,

            commandBar.topAnchor.constraint(equalTo: passthroughBanner.bottomAnchor),
            commandBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ]
        for contentView in contentViews {
            constraints += [
                contentView.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
                contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: statusDivider.topAnchor),
            ]
        }
        constraints += [
            statusDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            transferProgressBar.topAnchor.constraint(equalTo: statusDivider.bottomAnchor),
            transferProgressBar.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Spacing.medium),
            transferProgressBar.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Spacing.medium),
            transferBarCollapsed,

            statusBar.topAnchor.constraint(equalTo: transferProgressBar.bottomAnchor),
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

    override func viewDidAppear() {
        super.viewDidAppear()
        // Now visible — pull representations for an offer that arrived while hidden.
        triggerPreviewMaterialization()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard instance.clipboardService != nil else {
            Self.logger.warning(
                "Clipboard edit ignored — clipboardService is nil for VM '\(self.instance.name, privacy: .public)'")
            return
        }
        // Per keystroke: only cheap, hash-free work (CLIPBOARD.md §8).
        let text = textView.string
        editSeq &+= 1
        hasPendingEdit = true
        indicatorView.setText(ClipboardContentDescriber.indicatorText(forPlainText: text))
        commandBar.copyButton.isEnabled = !text.isEmpty && !isCopyingToMac
        commandBar.clearButton.isEnabled = !text.isEmpty
        scheduleEditCommit(text: text, seq: editSeq)
    }

    /// Schedules the off-actor commit of `text` after a quiet period, replacing
    /// any still-pending commit.
    private func scheduleEditCommit(text: String, seq: UInt64) {
        editDebounceTask?.cancel()
        editDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.editDebounceInterval ?? .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.commitEdit(text: text, seq: seq)
        }
    }

    /// Hashes the editor buffer off the main actor and writes it to the model,
    /// unless a newer keystroke or a guest update superseded this edit.
    private func commitEdit(text: String, seq: UInt64) async {
        guard let service = instance.clipboardService else { return }
        let edited = await ClipboardContent.makeOffActor(text: text)
        // A newer keystroke (seq) or a guest update that rebuilt the editor while
        // the hash ran (string mismatch) supersedes this commit; the newer writer
        // owns the model.
        guard seq == editSeq, textView.string == text else { return }
        hasPendingEdit = false
        hasUserEdit = true
        // Prime the digest before the write so the observation pass doesn't
        // rebuild the view out from under the user.
        lastAppliedDigest = edited.digest
        service.clipboardContent = edited
    }

    /// Synchronously commits the live editor text if a keystroke has not yet
    /// reached the model, so a grab/copy/close offers the latest text.
    func flushPendingEdit() {
        editDebounceTask?.cancel()
        editDebounceTask = nil
        guard hasPendingEdit, let service = instance.clipboardService else { return }
        hasPendingEdit = false
        hasUserEdit = true
        let edited = ClipboardContent(text: textView.string)
        lastAppliedDigest = edited.digest
        service.clipboardContent = edited
    }

    /// The window's blur/close hand-off: commit a pending keystroke, then announce
    /// the buffer — but only content the user typed here.
    ///
    /// The `hasUserEdit` guard is not redundant with `grabIfChanged()`, which
    /// answers "does this differ from the last *successful* send" — also true of
    /// content nobody touched whose send failed. Announcing unconditionally here
    /// would retry other components' failed transfers.
    func flushAndAnnounceEdit() {
        flushPendingEdit()
        guard hasUserEdit else { return }
        instance.clipboardService?.grabIfChanged()
    }

    /// Drops any pending edit without committing it.
    ///
    /// Called when an external update rebuilds the editor, so a superseded edit
    /// can't later flush stale text over the new content, or be announced.
    private func cancelPendingEdit() {
        editDebounceTask?.cancel()
        editDebounceTask = nil
        hasPendingEdit = false
        hasUserEdit = false
    }

    #if DEBUG
    /// Simulates a keystroke burst landing `text` in the editor.
    func setEditorTextForTesting(_ text: String) {
        textView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    /// Runs one UI/observation pass, as the service-change observer would.
    func simulateObservationForTesting() {
        updateUI()
    }

    var isCommandBarHiddenForTesting: Bool { commandBar.isHidden }

    /// The command bar's laid-out height, so a test can assert the collapse
    /// resolves to zero rather than only that `isHidden` was set.
    var commandBarLaidOutHeightForTesting: CGFloat { commandBar.frame.height }

    var isCopyingToMacForTesting: Bool { isCopyingToMac }

    /// The indicator slot's current text — the persistent content-type line, or a
    /// transient message while one is up.
    var indicatorTextForTesting: String { indicatorView.stringValue }

    /// Fires once a "Copy to Mac" publish outcome has been rendered.
    var onCopyOutcomeForTesting: (@MainActor () -> Void)?
    #endif

    // MARK: - Observation

    private func observeServiceChanges() {
        serviceObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                // Read each property so observation re-fires when any transitions.
                let clipService = self.instance.clipboardService
                _ = clipService?.clipboardContent
                _ = clipService?.isConnected
                _ = self.issueCenter.latestByInstance[self.instance.instanceID]
                _ = self.instance.vsockControlService?.agentStatus
                _ = self.instance.agentStatus
                _ = self.instance.configuration.clipboardPassthroughEnabled
            },
            apply: { [weak self] in
                self?.updateUI()
            }
        )

        // The transfer bar updates at chunk-flush cadence — many times a second
        // for a multi-GB transfer. Its own loop keeps a progress flush from
        // running the full `updateUI()` (content re-diff, preview materialization).
        transferProgressObservation = observeRecurring(
            track: { [weak self] in _ = self?.instance.clipboardService?.transferProgress },
            apply: { [weak self] in
                guard let self else { return }
                self.updateTransferProgress(service: self.instance.clipboardService)
            }
        )
    }

    /// Shows the bottom transfer bar from `transferProgress`; `nil` collapses it,
    /// so the bar can never get stuck.
    private func updateTransferProgress(service: ClipboardServicing?) {
        guard let progress = service?.transferProgress else {
            // Hide first, then reset the value while hidden so the next transfer
            // starts from 0 instead of animating down from a stale 100%.
            transferProgressBar.isHidden = true
            transferProgressBar.doubleValue = 0
            transferBarCollapsed.isActive = true
            transferProgressBar.toolTip = nil
            return
        }
        if transferProgressBar.isHidden {
            transferBarCollapsed.isActive = false
            transferProgressBar.isHidden = false
        }
        transferProgressBar.doubleValue = progress.fractionComplete
        transferProgressBar.toolTip = Self.transferTooltip(for: progress)
    }

    private static func transferTooltip(for progress: ClipboardProgressSnapshot) -> String {
        ClipboardProgressFormat.summary(progress)
    }

    private func updateUI() {
        let service = instance.clipboardService
        let status = instance.agentStatus
        let canInstallKernovaAgent = instance.configuration.guestOS == .macOS

        let hasContent = service != nil && !(service?.clipboardContent.isEmpty ?? true)
        textView.isEditable = service != nil
        commandBar.pasteButton.isEnabled = service != nil
        commandBar.copyButton.isEnabled = hasContent && !isCopyingToMac
        commandBar.clearButton.isEnabled = hasContent

        updateTransferProgress(service: service)

        if let service {
            let content = service.clipboardContent
            if content.digest != lastAppliedDigest {
                // An external update is replacing the editor; drop any debounced
                // edit so it can't later flush stale text over this content.
                cancelPendingEdit()
                lastAppliedDigest = content.digest
                apply(content: content)
                indicatorView.setText(ClipboardContentDescriber.indicatorText(for: content))
            }
        }

        if let notice = issueCenter.latestByInstance[instance.instanceID],
            notice.issue != lastShownIssue
        {
            lastShownIssue = notice.issue
            indicatorView.showTransientMessage(message(for: notice), style: .error)
        }

        applyStatus(status, canInstallKernovaAgent: canInstallKernovaAgent)
        updatePassthroughChrome()
        triggerPreviewMaterialization()
    }

    /// Reveals the passthrough banner and hides the manual command bar while
    /// automatic passthrough is on.
    private func updatePassthroughChrome() {
        let on = instance.configuration.clipboardPassthroughEnabled
        if passthroughBanner.isHidden == on {
            passthroughBanner.isHidden = !on
            passthroughBannerCollapsed.isActive = !on
        }
        guard commandBar.isHidden != on else { return }
        // Full Keyboard Access can park focus on a command button; move it off
        // before the bar disappears.
        if on, let responder = view.window?.firstResponder as? NSView,
            responder.isDescendant(of: commandBar)
        {
            view.window?.makeFirstResponder(dropContainer)
        }
        commandBar.isHidden = on
        commandBarCollapsed.isActive = on
    }

    private func disablePassthrough() {
        viewModel?.updateConfiguration(of: instance) { $0.clipboardPassthroughEnabled = false }
    }

    /// Pulls the representations the window renders richly, when it is visible.
    ///
    /// The service guards against re-pulling per generation, so calling this on
    /// every appear/update is cheap.
    private func triggerPreviewMaterialization() {
        guard let service = instance.clipboardService, view.window?.isVisible == true else { return }
        Task { await service.materializeForPreview() }
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
                summaryView.configure(content: content)
                show(contentView: summaryView)
            }
        case .image(let data, let uti):
            if imagePreview.configure(data: data, uti: uti) {
                show(contentView: imagePreview)
            } else {
                summaryView.configure(content: content)
                show(contentView: summaryView)
            }
        case .imageFile(let url, let uti):
            if imagePreview.configure(url: url, uti: uti) {
                show(contentView: imagePreview)
            } else if let file = content.filePayloads.first {
                filePreview.configure(
                    filename: file.filename, uti: file.uti, byteCount: file.byteCount)
                show(contentView: filePreview)
            } else {
                summaryView.configure(content: content)
                show(contentView: summaryView)
            }
        case .file(let filename, let uti, let byteCount):
            filePreview.configure(filename: filename, uti: uti, byteCount: byteCount)
            show(contentView: filePreview)
        case .files:
            filesPreview.configure(content: content)
            show(contentView: filesPreview)
        case .summary:
            summaryView.configure(content: content)
            show(contentView: summaryView)
        case .concealed:
            // The secret bytes are never handed to a view.
            show(contentView: concealedPreview)
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

    private func message(for notice: ClipboardIssueCenter.Notice) -> String {
        notice.issue.displayMessage(pasteLimitBytes: notice.pasteLimitBytes)
    }

    /// The message shown when "Copy to Mac" placed nothing on the pasteboard.
    private func dropMessage(for reasons: [CopyToMacDropReason]) -> String {
        guard reasons.contains(.overPasteBudget) else {
            return "Couldn't fetch the clipboard content to copy"
        }
        return ClipboardTransferIssue.overCopyBudgetMessage(
            limitBytes: instance.effectiveClipboardMaxPasteBytes)
    }

    // MARK: - Actions

    @objc private func pasteFromMac(_: Any?) {
        takeIn(pasteboard: readPasteboard)
    }

    /// Empties the window's clipboard buffer.
    ///
    /// Clears only the gated buffer/preview — the host and guest pasteboards
    /// are the user's real clipboards and are left untouched.
    @objc private func clearClipboard(_: Any?) {
        guard let service = instance.clipboardService, !service.clipboardContent.isEmpty else {
            return
        }
        // clearBuffer (not `clipboardContent = .empty`) also resets the send
        // dedup, so re-copying the just-cleared content still reaches the guest.
        service.clearBuffer()
        Self.logger.notice(
            "Cleared clipboard buffer for VM '\(self.instance.name, privacy: .public)'")
    }

    @objc private func copyToMac(_: Any?) {
        flushPendingEdit()
        guard let service = instance.clipboardService else { return }
        guard !service.clipboardContent.isEmpty else { return }
        guard !isCopyingToMac else { return }
        isCopyingToMac = true

        commandBar.copyButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isCopyingToMac = false
                self.commandBar.copyButton.isEnabled = !service.clipboardContent.isEmpty
            }
            let outcome = await self.publisher.publish(from: service)
            self.showCopyOutcome(outcome)
        }
    }

    /// Surfaces a "Copy to Mac" publish result as a transient status message.
    private func showCopyOutcome(_ outcome: HostPublishOutcome) {
        switch outcome {
        case .nothingServed(let reasons):
            indicatorView.showTransientMessage(dropMessage(for: reasons), style: .error)
        case .stagingFailed:
            indicatorView.showTransientMessage(
                "Couldn't prepare the clipboard content to copy", style: .error)
        case .written(_, let droppedReasons, _):
            if droppedReasons.isEmpty {
                indicatorView.showTransientMessage("Copied to Mac clipboard", style: .info)
            } else if droppedReasons.contains(.overPasteBudget) {
                // Partial success — name the cap, since it is what the user has to
                // act on to get the files across.
                indicatorView.showTransientMessage(
                    "Copied without the files — over the \(ClipboardPasteLimit.displayLimit(instance.effectiveClipboardMaxPasteBytes)) clipboard transfer limit",
                    style: .warning)
            } else {
                // Partial success — don't claim an unqualified one.
                let count = droppedReasons.count
                indicatorView.showTransientMessage(
                    "Copied to Mac clipboard — \(count) item\(count == 1 ? "" : "s") couldn't be prepared",
                    style: .warning)
            }
        case .writeFailed:
            indicatorView.showTransientMessage("Couldn't write to the Mac clipboard", style: .error)
        }
        #if DEBUG
        onCopyOutcomeForTesting?()
        #endif
    }

    /// Shared intake for the Paste button, responder-chain `paste:`, and drag-and-drop.
    ///
    /// Paste/drop are complete gestures — the content is sent to the guest
    /// immediately, unlike typed edits which send on window blur.
    private func takeIn(pasteboard: NSPasteboard) {
        guard let service = instance.clipboardService else { return }
        let allowsBinary = service.supportsBinaryRepresentations
        let result = ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: allowsBinary)
        if case .pendingFiles(let urls, let unresolved) = result {
            resolveAndApply(pendingFiles: urls, unresolved: unresolved, allowsBinary: allowsBinary)
        } else {
            _ = apply(intake: result)
        }
    }

    /// Resolves `.pendingFiles` URLs off the main actor and applies the result
    /// on the way back.
    private func resolveAndApply(pendingFiles urls: [URL], unresolved: Int, allowsBinary: Bool) {
        Task { @MainActor [weak self] in
            let resolved = await ClipboardPasteboardIntake.read(
                filesAt: urls, unresolved: unresolved, allowsBinary: allowsBinary)
            _ = self?.apply(intake: resolved)
        }
    }

    private func apply(intake: ClipboardIntakeResult) -> Bool {
        guard let service = instance.clipboardService else { return false }

        switch intake {
        case .content(let content, let note):
            service.clipboardContent = content
            service.grabIfChanged()
            if let note {
                indicatorView.showTransientMessage(note, style: .warning)
            }
            Self.logger.info(
                "Took in pasteboard content (\(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
            )
            return true
        case .rejected(let message, _):
            indicatorView.showTransientMessage(message, style: .warning)
            Self.logger.info("Pasteboard intake rejected: \(message, privacy: .public)")
            return false
        case .pendingFiles:
            Self.logger.fault(
                "apply(intake:) received .pendingFiles — resolve it via read(filesAt:) first")
            assertionFailure("apply(intake:) received .pendingFiles")
            return false
        }
    }

    // MARK: - Drag-and-drop

    /// Routes a performed drop, image-first, so a dragged screenshot shows the
    /// image like other Mac apps.
    ///
    /// Synchronous intake handles inline image data, a file already on disk, and
    /// plain/rich text — and never surfaces a path string for a file/promise
    /// drag. Only when nothing usable resolves synchronously is a file promise
    /// received asynchronously.
    private func handleDrop(_ draggingInfo: NSDraggingInfo) -> Bool {
        guard let service = instance.clipboardService else { return false }
        let pasteboard = draggingInfo.draggingPasteboard

        Self.logger.debug(
            "Clipboard drop types: \(pasteboard.pasteboardItems?.first?.types.map(\.rawValue).joined(separator: ", ") ?? "none", privacy: .public)"
        )

        let allowsBinary = service.supportsBinaryRepresentations
        let result = ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: allowsBinary)
        switch result {
        case .content:
            return apply(intake: result)
        case .pendingFiles(let urls, let unresolved):
            // Accept the drop now; resolve the files/folders off the main actor
            // (the dragging pasteboard was already consumed synchronously above).
            resolveAndApply(pendingFiles: urls, unresolved: unresolved, allowsBinary: allowsBinary)
            return true
        case .rejected:
            if let receiver = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])?
                .compactMap({ $0 as? NSFilePromiseReceiver }).first
            {
                receivePromisedFile(receiver)
                return true
            }
            return apply(intake: result)
        }
    }

    /// Receives a promised file into the service's drop staging and runs it
    /// through the shared file intake.
    ///
    /// The winning item stays on disk: the buffer's representation is
    /// disk-backed (a stat'd file, or a folder source rep archived only at
    /// request time), so it must outlive this receipt — the service reclaims the
    /// directory once nothing can read from it. Losing and failed receipts clean
    /// their own files up.
    private func receivePromisedFile(_ receiver: NSFilePromiseReceiver) {
        guard let service = instance.clipboardService else { return }
        let allowsBinary = service.supportsBinaryRepresentations
        guard allowsBinary else {
            // A text-only transport rejects the file whatever it holds, so say so
            // instead of writing it out first.
            indicatorView.showTransientMessage(
                ClipboardPasteboardIntake.textOnlyTransportMessage, style: .warning)
            return
        }

        indicatorView.showTransientMessage("Receiving dropped file…", style: .info)

        guard let destination = service.reserveDropDestination() else {
            indicatorView.showTransientMessage("Couldn't receive the dropped file", style: .error)
            Self.logger.error("Failed to reserve a directory for the dropped file promise")
            return
        }

        // The reader block runs once per promised file. The buffer models a
        // single item, so the first successfully received file wins.
        let firstFileGate = PromiseFirstFileGate()

        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) {
            [weak self] url, error in
            Task { @MainActor [weak self] in
                // Every file but the winner goes now, even if the window closed
                // before the promise resolved; the winner's on-disk bytes back
                // the buffer's representation, and the directory holding it is
                // the service's to reclaim.
                var keepFile = false
                defer { if !keepFile { try? FileManager.default.removeItem(at: url) } }
                guard let self else { return }
                if let error {
                    self.indicatorView.showTransientMessage("Couldn't receive the dropped file", style: .error)
                    Self.logger.error(
                        "File promise receipt failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                guard !firstFileGate.taken else { return }
                firstFileGate.taken = true
                let resolved = await ClipboardPasteboardIntake.read(
                    filesAt: [url], allowsBinary: allowsBinary)
                keepFile = self.apply(intake: resolved)
            }
        }
    }

    // MARK: - Responder-chain edit actions

    // Cover image/summary/empty-unfocused modes; in text mode the focused
    // NSTextView handles Cmd+V/Cmd+C natively.
    //
    // Each body re-checks `isPassthroughOn` rather than trusting
    // `validateUserInterfaceItem`: validation is advisory, and a direct
    // `sendAction` reaches the action regardless.
    @objc func paste(_ sender: Any?) {
        guard !isPassthroughOn else { return }
        takeIn(pasteboard: readPasteboard)
    }

    @objc func copy(_ sender: Any?) {
        guard !isPassthroughOn else { return }
        copyToMac(sender)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)):
            return !isPassthroughOn && instance.clipboardService != nil
        case #selector(copy(_:)):
            guard !isPassthroughOn, let service = instance.clipboardService else { return false }
            return !service.clipboardContent.isEmpty && !isCopyingToMac
        default:
            return true
        }
    }

    /// `true` while automatic passthrough owns the transfer.
    ///
    /// The manual actions are withdrawn. A focused `NSTextView` handles
    /// `paste:`/`copy:` itself, so editor text editing is unaffected.
    private var isPassthroughOn: Bool { instance.configuration.clipboardPassthroughEnabled }

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
            // No install/reinstall affordance — the agent is expected to
            // reconnect; the watchdog surfaces `.expectedMissing` if it doesn't.
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
        // NSView's default hugging priority (250) matches the label's, so without
        // lowering it the stack view has no signal to grow the spacer rather than
        // the label, and the button wouldn't sit flush against the trailing edge.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [statusCircle, statusLabel, spacer, indicatorView, actionButton])
        stack.orientation = .horizontal
        stack.spacing = Spacing.small
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.alignment = .centerY

        return stack
    }
}

/// The narrow slice of `NSPasteboard` the host write-back path needs, so a
/// test can substitute a fake that forces `writeObjects` to fail.
///
/// `NSPasteboard` is a class cluster with no public initializer and can't be
/// subclassed, so its write can't be made to fail from a test.
protocol HostWritePasteboard: AnyObject {
    /// Monotonically increasing count of pasteboard changes — the value right
    /// after a write identifies that write to a coordinator polling the same
    /// pasteboard.
    var changeCount: Int { get }
    @discardableResult func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
    /// Empties the pasteboard — the publisher's stale-promise retraction.
    @discardableResult func clearContents() -> Int
}

extension NSPasteboard: HostWritePasteboard {}
