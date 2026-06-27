import Cocoa
import KernovaKit
import os

/// Pure AppKit view controller for the clipboard sharing window content.
///
/// A command bar tops the window: explicit host-pasteboard actions
/// ("Paste from Mac" / "Copy to Mac", also reachable through the responder
/// chain as `paste:`/`copy:` outside the editor) plus "Clear" to empty the
/// buffer. Below it the content area renders the buffer per
/// `ClipboardPreviewPolicy`: an editable `NSTextView` for text (and the empty
/// buffer), a styled-RTF / image / file-chip preview, or a generic
/// per-representation summary; drag-and-drop anywhere in the window feeds the
/// same intake path as the Paste button. The bottom status bar shows the guest
/// agent connection state (and the install/update affordance for macOS guests —
/// Linux guests use `spice-vdagent`, so it's hidden for them) on the left and
/// the content-type indicator — which doubles as the transient status surface —
/// right-aligned.
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
    private let filesPreview = ClipboardFilesPreviewView()
    private let summaryView = ClipboardSummaryView()
    private let concealedPreview = ClipboardConcealedPreviewView()
    private let commandBar = ClipboardCommandBarView()
    /// Content-type indicator + transient-status surface, placed in the status
    /// row (right-aligned) so the command row stays a clean set of buttons.
    private let indicatorView = ClipboardIndicatorView()

    /// Determinate transfer progress bar, pinned just above the status row.
    ///
    /// Shown (and collapsed when idle via `transferBarCollapsed`) by
    /// `updateTransferProgress`.
    private let transferProgressBar = NSProgressIndicator()
    /// Active = the bar is collapsed to zero height (the idle resting state);
    /// deactivated to reveal the bar at its intrinsic system height.
    private lazy var transferBarCollapsed = transferProgressBar.heightAnchor.constraint(
        equalToConstant: 0)

    /// Every content view stacked in the content area; exactly one is visible.
    /// `scrollView` (the editable plain-text editor) is first — the default.
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
    /// When the observed model digest matches, the content rebuild is
    /// skipped — both for cheap no-op passes and for the echo of our own
    /// writes.
    private var lastAppliedDigest: Data?

    /// Debounced off-actor commit of the editor buffer.
    ///
    /// `textDidChange` does only cheap, hash-free work per keystroke (CLIPBOARD.md
    /// §8) and schedules this; after `editDebounceInterval` of quiet the buffer is
    /// hashed off the main actor and written to the model. `editSeq` bumps per
    /// keystroke so an in-flight commit can tell it was superseded; `hasPendingEdit`
    /// records that a keystroke has not yet reached the model, so `flushPendingEdit`
    /// can commit the latest text synchronously before a grab/copy.
    private var editDebounceTask: Task<Void, Never>?
    private var editSeq: UInt64 = 0
    private var hasPendingEdit = false

    /// Quiet period before a keystroke burst commits off-actor.
    ///
    /// Injectable so tests drive the commit deterministically instead of waiting
    /// out 200 ms.
    private let editDebounceInterval: Duration

    /// Last transfer issue already shown as a transient.
    ///
    /// Tracked so re-observation doesn't re-show it; compared by value
    /// (`date` is the re-fire identity).
    private var lastShownIssue: ClipboardTransferIssue?

    private var serviceObservation: ObservationLoop?
    /// Drives only the bottom transfer bar, separate from `serviceObservation`.
    ///
    /// Chunk-cadence progress flushes then refresh just the bar — not the full
    /// `updateUI()`. See `observeServiceChanges()`.
    private var transferProgressObservation: ObservationLoop?

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

    /// Materializes inline file payloads (e.g. an image file shown in place) to
    /// local temp files for "Copy to Mac" so a Finder paste creates the file.
    ///
    /// A streamed `.file` payload already has a temp URL and isn't re-staged here.
    /// Recent generations are retained (see `ClipboardFileStaging`) so a
    /// just-copied URL on the pasteboard stays valid across a couple more copies.
    private let staging = ClipboardFileStaging(label: ClipboardContentViewController.stagingLabel)

    /// Monotonic generation for the window's launch-swept staging root.
    ///
    /// Bumped by both "Copy to Mac" (files/folders staged for the pasteboard) and
    /// outbound folder archiving, so each operation supersedes older staged
    /// artifacts within `ClipboardFileStaging`'s recency window. One shared
    /// counter is correct here: both uses key on this *local* counter and one
    /// `staging` instance, so there is no generation-namespace collision. The
    /// guest, by contrast, needs a separate `sendStaging` because its inbound
    /// staging keys on the host's offer generation — a foreign namespace an
    /// outbound counter could collide with.
    private var stagingGeneration: UInt64 = 1

    /// `true` while a "Copy to Mac" is materializing/writing.
    ///
    /// The async pull republishes `clipboardContent`, which re-fires the
    /// observation pass and would re-enable the Copy button mid-copy; this flag is
    /// the real re-entrancy guard, not the button's enabled state.
    private var isCopyingToMac = false

    /// Destination pasteboard for "Copy to Mac".
    ///
    /// `.general` in production; tests inject a private `NSPasteboard(name:)` to
    /// exercise the write/retention path without touching the developer's real
    /// clipboard, or a `HostWritePasteboard` fake to force a write failure (the
    /// concrete `NSPasteboard` can't be made to fail). See `HostWritePasteboard`.
    private let writePasteboard: any HostWritePasteboard

    /// Process-lifetime owner of the lazy data providers a "Copy to Mac" writes.
    ///
    /// RATIONALE: a promised pasteboard item can be pasted long after this
    /// window closes (and the window auto-closes when the VM stops), so the
    /// providers must outlive the controller — they live in this app-scoped
    /// registry rather than on `self`. See `LazyClipboardProviderRegistry`.
    private let providerRegistry: LazyClipboardProviderRegistry

    /// First-file-wins gate shared by one promise receipt's per-file
    /// completions (the buffer models a single pasteboard item).
    @MainActor
    private final class PromiseFirstFileGate {
        var taken = false
    }

    init(
        instance: VMInstance, viewModel: VMLibraryViewModel,
        writePasteboard: any HostWritePasteboard = NSPasteboard.general,
        providerRegistry: LazyClipboardProviderRegistry = .shared,
        editDebounceInterval: Duration = .milliseconds(200)
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.writePasteboard = writePasteboard
        self.providerRegistry = providerRegistry
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

        // Vertical order: command bar (top) → divider → content → divider →
        // progress bar → status row (bottom).
        var constraints: [NSLayoutConstraint] = [
            commandBar.topAnchor.constraint(equalTo: container.topAnchor),
            commandBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            commandDivider.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            commandDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            commandDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ]
        for contentView in contentViews {
            constraints += [
                contentView.topAnchor.constraint(equalTo: commandDivider.bottomAnchor),
                contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: statusDivider.topAnchor),
            ]
        }
        constraints += [
            statusDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // The progress bar sits between the divider and the status row, inset
            // to align with the status row's content. Collapsed to zero height at
            // rest, so the resting layout is pixel-identical to before.
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
        // The window is now visible — pull the representations it renders richly
        // for a guest offer that arrived (or stayed a placeholder) while hidden.
        triggerPreviewMaterialization()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard instance.clipboardService != nil else {
            Self.logger.warning(
                "Clipboard edit ignored — clipboardService is nil for VM '\(self.instance.name, privacy: .public)'")
            return
        }
        // Per keystroke: only cheap, hash-free work (CLIPBOARD.md §8). The
        // indicator and button state derive from the live string; the buffer's
        // content/digest is committed off-actor by the debounced `commitEdit`.
        let text = textView.string
        editSeq &+= 1
        hasPendingEdit = true
        indicatorView.setText(ClipboardContentDescriber.indicatorText(forPlainText: text))
        commandBar.copyButton.isEnabled = !text.isEmpty && !isCopyingToMac
        commandBar.clearButton.isEnabled = !text.isEmpty
        scheduleEditCommit(text: text, seq: editSeq)
    }

    /// Schedules the off-actor commit of `text` after a quiet period, replacing
    /// any still-pending commit (mirrors `VMDirectoryWatcher.scheduleReconciliation`).
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
        // the hash ran (string mismatch) supersedes this commit; dropping it is
        // safe — the newer writer owns the model.
        guard seq == editSeq, textView.string == text else { return }
        hasPendingEdit = false
        // Prime the digest before the write so the resulting observation pass
        // recognizes the content as already displayed (the editor IS the source)
        // and doesn't rebuild the view out from under the user.
        lastAppliedDigest = edited.digest
        service.clipboardContent = edited
    }

    /// Synchronously commits the live editor text if a keystroke has not yet
    /// reached the model, so a grab/copy/close offers the latest text.
    ///
    /// A no-op in the common case (the debounced commit already landed), so no
    /// hash is paid; when an edit is pending it pays a single synchronous hash on
    /// a discrete user action — acceptable under §8 (it is not per keystroke).
    func flushPendingEdit() {
        editDebounceTask?.cancel()
        editDebounceTask = nil
        guard hasPendingEdit, let service = instance.clipboardService else { return }
        hasPendingEdit = false
        let edited = ClipboardContent(text: textView.string)
        lastAppliedDigest = edited.digest
        service.clipboardContent = edited
    }

    /// Drops any pending edit without committing it.
    ///
    /// Called when an external update rebuilds the editor, so a superseded
    /// in-progress edit can't later flush stale text over the new content.
    private func cancelPendingEdit() {
        editDebounceTask?.cancel()
        editDebounceTask = nil
        hasPendingEdit = false
    }

    #if DEBUG
    /// Simulates a keystroke burst landing `text` in the editor — sets the
    /// text view and fires the delegate callback — so tests drive the
    /// debounced off-actor commit without synthesizing real key events.
    func setEditorTextForTesting(_ text: String) {
        textView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    /// Runs one UI/observation pass, as the service-change observer would, so
    /// tests can drive the external-update rebuild path (which cancels a
    /// pending edit) deterministically.
    func simulateObservationForTesting() {
        updateUI()
    }
    #endif

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

        // The transfer bar updates at chunk-flush cadence — many times a second
        // for a multi-GB transfer. Drive it from its own lightweight loop so a
        // progress flush refreshes only the bar, not the full `updateUI()` (which
        // re-diffs the content digest and re-triggers lazy preview
        // materialization). Mirrors the toolbar item's dedicated progress loop.
        transferProgressObservation = observeRecurring(
            track: { [weak self] in _ = self?.instance.clipboardService?.transferProgress },
            apply: { [weak self] in
                guard let self else { return }
                self.updateTransferProgress(service: self.instance.clipboardService)
            }
        )
    }

    /// Shows/collapses the bottom transfer bar from the service's `transferProgress`.
    /// `nil` (no active transfer, or cleared on any terminal state) collapses it, so
    /// the bar can never get stuck.
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

    private static func transferTooltip(for progress: ClipboardTransferProgress) -> String {
        let verb = progress.direction == .inbound ? "Receiving" : "Sending"
        let done = DataFormatters.formatBytes(UInt64(max(0, progress.bytesTransferred)))
        let total = DataFormatters.formatBytes(UInt64(max(0, progress.totalBytes)))
        return "\(verb)… \(done) of \(total)"
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
                // An external update (guest content, paste) is replacing the
                // editor; drop any debounced edit so it can't later flush stale
                // text over this content. (Our own primed writes match the digest
                // and never reach this branch.)
                cancelPendingEdit()
                lastAppliedDigest = content.digest
                apply(content: content)
                indicatorView.setText(ClipboardContentDescriber.indicatorText(for: content))
            }
            if let issue = service.lastTransferIssue, issue != lastShownIssue {
                lastShownIssue = issue
                indicatorView.showTransientMessage(message(for: issue), style: .error)
            }
        }

        applyStatus(status, canInstallKernovaAgent: canInstallKernovaAgent)
        triggerPreviewMaterialization()
    }

    /// Pulls the representations the window renders richly for the current guest
    /// offer, when the window is visible — the lazy "pull on display" trigger.
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
        case .imageFile(let url, let uti):
            if imagePreview.configure(url: url, uti: uti) {
                show(contentView: imagePreview)
            } else if let file = content.filePayloads.first {
                // Unreadable/undecodable file image degrades to the file chip.
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
            // The placeholder is static — nothing to configure; the secret bytes
            // are never handed to a view.
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

    private func message(for issue: ClipboardTransferIssue) -> String {
        switch issue.kind {
        case .contentTooLarge(let byteCount, let limit):
            return
                "Content is too large to send (\(DataFormatters.formatBytes(UInt64(byteCount))) — limit \(DataFormatters.formatBytes(UInt64(limit))))"
        case .diskFull(let needed, let available):
            if let available {
                return
                    "Not enough disk space to receive the clipboard file (\(DataFormatters.formatBytes(UInt64(needed))) needed, \(DataFormatters.formatBytes(UInt64(available))) free)"
            }
            return
                "Not enough disk space to receive the clipboard file (\(DataFormatters.formatBytes(UInt64(needed))) needed)"
        case .peerReportedError(let code, _):
            switch code {
            case "clipboard.transfer.too.large":
                return "The guest rejected the transfer as too large"
            case "clipboard.format.unavailable":
                return "The guest couldn't provide the requested format"
            case "clipboard.paste.disk.full":
                return "The guest ran out of disk space receiving the clipboard file"
            case "clipboard.paste.timeout":
                return "The clipboard transfer to the guest timed out"
            default:
                return "Clipboard transfer failed on the guest side"
            }
        }
    }

    // MARK: - Actions

    @objc private func pasteFromMac(_: Any?) {
        takeIn(pasteboard: .general)
    }

    /// Empties the window's clipboard buffer.
    ///
    /// Clears only the gated buffer/preview — the host and guest pasteboards
    /// are the user's real clipboards and are left untouched. The observation
    /// pass resets the editor to empty and the indicator to "Empty".
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
        // Commit any keystroke still inside the debounce window so an immediate
        // type-then-Copy offers the latest text (and passes the emptiness guard).
        flushPendingEdit()
        guard let service = instance.clipboardService else { return }
        guard !service.clipboardContent.isEmpty else { return }
        // A pull landing mid-copy republishes clipboardContent, firing the
        // observation pass that re-enables the Copy button (updateUI) while this
        // copy is still in flight. Guard re-entry explicitly so a second click
        // can't launch a concurrent materialize + last-writer-wins pasteboard
        // write; the disabled button is only cosmetic.
        guard !isCopyingToMac else { return }
        isCopyingToMac = true

        let staging = self.staging
        let generation = stagingGeneration
        stagingGeneration += 1
        // Pull any not-yet-fetched representations first (lazy mode), then build
        // the pasteboard pairs off the main actor: a streamed `.file` payload's
        // temp URL is used as-is; an inline payload's bytes are written inline
        // (read from disk if file-backed); an inline-and-named payload (image
        // file) is also staged to a temp file so a Finder paste creates it. A
        // large read/stage/pull mustn't block the UI, so disable the button until
        // it resolves.
        commandBar.copyButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isCopyingToMac = false
                self.commandBar.copyButton.isEnabled = !service.clipboardContent.isEmpty
            }
            let content = await service.materializeForCopy()
            guard !content.isEmpty else {
                self.indicatorView.showTransientMessage(
                    "Couldn't fetch the clipboard content to copy", style: .error)
                return
            }
            let specs = await Self.hostPasteboardItems(
                for: content, generation: generation, staging: staging)
            // One lazy provider per item: its bytes are read only when a
            // destination pastes that type (the laziness #392 restores). The
            // providers outlive this window — `finishCopyToMac` hands them to the
            // app-scoped registry (not self) once the write succeeds, so a paste
            // after the window closes still finds a live provider.
            let registry = self.providerRegistry
            var providers: [LazyClipboardDataProvider] = []
            let items = specs.map { spec -> NSPasteboardItem in
                let item = NSPasteboardItem()
                let provider = LazyClipboardDataProvider(
                    provide: spec.provide,
                    onFinished: { provider in
                        // The registry is internally locked, so this nonisolated
                        // callback (fired by NSPasteboard on the main run loop)
                        // drops the provider directly. Captures the registry, not
                        // the VC, so the provider's lifetime is decoupled from this
                        // controller.
                        registry.release(provider)
                    })
                item.setDataProvider(provider, forTypes: spec.types)
                providers.append(provider)
                return item
            }
            // Each successfully staged/extracted file payload yields exactly one
            // item promising a `.fileURL`; any shortfall is a payload (often a
            // folder whose extraction failed) silently dropped — surface it rather
            // than showing an unqualified success.
            let stagedFileCount = items.filter { $0.types.contains(.fileURL) }.count
            let droppedFiles = content.filePayloads.count - stagedFileCount
            self.finishCopyToMac(
                items: items, providers: providers,
                representationCount: content.representations.count,
                droppedFiles: droppedFiles)
        }
    }

    /// One pasteboard item to write for "Copy to Mac": the types it promises and
    /// a closure that lazily serves the bytes for each requested type.
    ///
    /// The spec is the lazy counterpart of an eager `[(type, data)]` item — the
    /// inline byte read is deferred into `provide`, which the
    /// `LazyClipboardDataProvider` invokes only when a destination actually
    /// pastes that type. File URLs are resolved eagerly (staging stays the
    /// temporary bridge until the File Provider transport lands), so a file
    /// payload's `.fileURL` is captured by the closure but its image bytes are
    /// still served on demand.
    struct PasteboardItemSpec: Sendable {
        let types: [NSPasteboard.PasteboardType]
        let provide: @Sendable (NSPasteboard.PasteboardType) -> Data?
    }

    /// Builds the per-item provider specs to promise on the host pasteboard for
    /// `content`, staging file URLs off the main actor while deferring inline
    /// byte reads to paste time.
    ///
    /// A single inline item promises every inline (filename-less) representation;
    /// each file payload becomes its own item promising exactly one `.fileURL`
    /// (and, for an image file, its inline image bytes too). One `.fileURL` per
    /// item is what a Finder paste needs to create N files — a single item holds
    /// only one value per type, so several file URLs in one item would collide.
    /// Mirrors the guest agent's inbound promise grouping.
    ///
    /// Internal (not `private`) so `@testable import` can exercise this pure
    /// grouping/staging step — and each spec's `provide` closure — directly
    /// without driving the whole controller.
    nonisolated static func hostPasteboardItems(
        for content: ClipboardContent, generation: UInt64, staging: ClipboardFileStaging
    ) async -> [PasteboardItemSpec] {
        // The grouping decision (one shared inline item; one item per file
        // payload; UTI dedup) is the shared planner — the single source of truth
        // both sides of the bridge use. This side maps each planned item to a
        // lazy `PasteboardItemSpec`, staging file URLs eagerly (the temporary
        // bridge until the File Provider transport lands) while deferring inline
        // byte reads to paste time.
        let descriptors = content.representations.map {
            ClipboardRepresentationDescriptor(
                uti: $0.uti, filename: $0.filename,
                isInline: $0.shouldInlineOnPasteboard, isPromisable: true)
        }
        let plan = ClipboardPasteboardItemPlan.plan(for: descriptors)

        var specs: [PasteboardItemSpec] = []
        for item in plan.items {
            if item.types.contains(where: \.isFileURL) {
                // A file payload — one item promising exactly one `.fileURL` (plus
                // inline image bytes for an image file). All of an item's types
                // share one backing rep. Same-named files get distinct staged URLs
                // from `ClipboardFileStaging`; the `.fileURL` is resolved now (eager
                // staging), the image bytes served on demand.
                let representation = content.representations[item.types[0].representationIndex]
                var types: [NSPasteboard.PasteboardType] = []
                // The planner emits the content (image) UTI before `.fileURL` iff the
                // rep inlines — promise that flavor from the same durable staged file.
                let imageType = item.types.first { !$0.isFileURL }
                    .map { NSPasteboard.PasteboardType($0.uti) }
                if let imageType { types.append(imageType) }

                // Stage the bytes into the window's launch-swept root and promise
                // THAT url: a file payload arrives as a `.file` whose `fileURL`
                // points into the service's transient staging (swept on VM stop),
                // whereas the adopted `stagedURL` outlives the VM connection. The
                // image flavor must read the same durable file — reading
                // `representation.fileURL` lazily would vend empty image bytes once
                // the transient file is swept, the very window-survival case the
                // provider registry exists to support.
                let stagedURL = stagedFileURL(
                    for: representation, generation: generation, staging: staging)
                let fileURLData = stagedURL.map { Data($0.absoluteString.utf8) }
                if fileURLData != nil { types.append(.fileURL) }

                guard !types.isEmpty else { continue }
                specs.append(
                    PasteboardItemSpec(types: types) { type in
                        if type == .fileURL { return fileURLData }
                        if type == imageType {
                            if let stagedURL,
                                let data = try? Data(contentsOf: stagedURL, options: .mappedIfSafe)
                            {
                                return data
                            }
                            // Staging produced no durable file — fall back to the
                            // rep's own bytes (resident, or a best-effort URL read).
                            return inlineData(for: representation)
                        }
                        return nil
                    })
            } else {
                // The shared inline item: promise every inline rep's content UTI,
                // reading the bytes lazily only when a destination pastes that type.
                var inlineByType: [NSPasteboard.PasteboardType: ClipboardContent.Representation] = [:]
                var inlineTypes: [NSPasteboard.PasteboardType] = []
                for promised in item.types {
                    let type = NSPasteboard.PasteboardType(promised.uti)
                    inlineByType[type] = content.representations[promised.representationIndex]
                    inlineTypes.append(type)
                }
                // Snapshot to a `let` so the @Sendable provider closure captures an
                // immutable map rather than the mutable `var` built above.
                let inlineReps = inlineByType
                specs.append(
                    PasteboardItemSpec(types: inlineTypes) { type in
                        inlineReps[type].flatMap(inlineData(for:))
                    })
            }
        }
        return specs
    }

    /// Resident bytes to inline for a representation, memory-mapped rather than
    /// read whole so a multi-GB image is never loaded into the heap. [L2]
    ///
    /// The bytes page in on demand and the OS can evict them under pressure. The
    /// caller gates this to image payloads (`shouldInlineOnPasteboard`), so there
    /// is no size ceiling to apply (CLIPBOARD.md §1).
    nonisolated private static func inlineData(
        for representation: ClipboardContent.Representation
    ) -> Data? {
        if let resident = representation.inMemoryData {
            return resident
        }
        if let url = representation.fileURL {
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        return nil
    }

    /// Stages a file payload's bytes under the window's launch-swept root and
    /// returns its URL, so the pasteboard `public.file-url` outlives the VM
    /// teardown.
    ///
    /// A directory payload is extracted from its streamed `.aar` into a real
    /// folder so a Finder paste recreates the tree. Otherwise re-homes a streamed
    /// `.file` out of the service's transient staging (swept on VM stop/reconnect)
    /// via `adopt`, or writes an inline-and-named payload's bytes to a fresh sink.
    /// [sweep-vs-URL]
    nonisolated private static func stagedFileURL(
        for representation: ClipboardContent.Representation, generation: UInt64,
        staging: ClipboardFileStaging
    ) -> URL? {
        if representation.isDirectory {
            // A directory rep's bytes are an `.aar` of the tree. Extract it into a
            // real folder under the launch-swept root so a Finder paste recreates
            // the tree, not the archive file. The shared helper (also used by the
            // guest agent) does the free-space floor check + extract.
            return ClipboardDirectoryArchive.extractedDirectoryURL(
                for: representation, into: staging, generation: generation)
        }
        if let existing = representation.fileURL {
            let adopted = try? staging.adopt(
                externalFile: existing, generation: generation,
                filename: representation.filename)
            return adopted ?? existing
        }
        guard let data = representation.inMemoryData,
            let sink = try? staging.makeSink(
                generation: generation, filename: representation.filename)
        else { return nil }
        do {
            try sink.write(data)
            return try sink.commit()
        } catch {
            // Don't offer a truncated file — abort the partial stage.
            sink.abort()
            return nil
        }
    }

    /// Writes the prepared pasteboard items to the Mac clipboard, surfacing
    /// success/failure.
    ///
    /// Split from `copyToMac(_:)` so the file-staging step can run off the main
    /// actor in between. `writeObjects` with several `NSPasteboardItem`s is the
    /// multi-item write a Finder paste turns into N files. `providers` are the
    /// lazy data providers backing `items`; they are handed to the app-scoped
    /// registry only after a successful write — an unwritten provider never gets a
    /// finish callback, so it needs no rollback and simply deallocates with the
    /// caller's local array.
    private func finishCopyToMac(
        items: [NSPasteboardItem], providers: [LazyClipboardDataProvider],
        representationCount: Int, droppedFiles: Int
    ) {
        // `hostPasteboardItems` emits a spec only with a non-empty `types`, and
        // `setDataProvider(_:forTypes:)` carries those onto each item, so an empty
        // `items` means every payload was dropped (e.g. a folder that failed to
        // extract). Surface that rather than clearing the Mac clipboard to write
        // nothing.
        guard !items.isEmpty else {
            indicatorView.showTransientMessage(
                "Couldn't prepare the clipboard content to copy", style: .error)
            Self.logger.error("copyToMac produced no pasteboard items (staging failed)")
            return
        }
        let pasteboard = writePasteboard
        pasteboard.clearContents()
        if pasteboard.writeObjects(items) {
            // The promise is live now, so hand provider ownership to the registry;
            // the caller's local array deallocates when this returns, but a paste
            // can land long after, including after the window closes.
            providerRegistry.retain(providers)
            if droppedFiles > 0 {
                // Partial success: some payloads (e.g. a folder that failed to
                // extract) were dropped — don't claim an unqualified success.
                indicatorView.showTransientMessage(
                    "Copied to Mac clipboard — \(droppedFiles) item\(droppedFiles == 1 ? "" : "s") couldn't be prepared",
                    style: .warning)
            } else {
                indicatorView.showTransientMessage("Copied to Mac clipboard", style: .info)
            }
            Self.logger.info(
                "Copied clipboard buffer to host pasteboard (\(representationCount, privacy: .public) reps, \(items.count, privacy: .public) items, \(droppedFiles, privacy: .public) dropped)"
            )
        } else {
            // The write failed, so the providers were never retained — the local
            // array drops them and no finish callback fires.
            indicatorView.showTransientMessage("Couldn't write to the Mac clipboard", style: .error)
            Self.logger.error("NSPasteboard.writeObjects failed for clipboard buffer")
        }
    }

    /// Shared intake for the Paste button, responder-chain `paste:`, and drag-and-drop.
    ///
    /// Paste/drop are complete gestures — the content is sent to the guest
    /// immediately, unlike typed edits which send on window blur.
    private func takeIn(pasteboard: NSPasteboard) {
        guard let service = instance.clipboardService else { return }
        let allowsBinary = service.supportsBinaryRepresentations
        let result = ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: allowsBinary)
        if case .pendingFiles(let urls) = result {
            resolveAndApply(pendingFiles: urls, allowsBinary: allowsBinary)
        } else {
            _ = apply(intake: result)
        }
    }

    /// Resolves `.pendingFiles` URLs off the main actor — archiving any folder
    /// into the staging root — and applies the result on the way back.
    ///
    /// Shared by the Paste / responder path and drag-and-drop.
    private func resolveAndApply(pendingFiles urls: [URL], allowsBinary: Bool) {
        let staging = self.staging
        let generation = stagingGeneration
        stagingGeneration += 1
        // A folder archives eagerly; warn the user it may take a moment. A cheap
        // stat only — the tree walk happens off-main in the resolve below.
        if Self.containsDirectory(urls) {
            indicatorView.showTransientMessage("Archiving folder…", style: .info)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await ClipboardPasteboardIntake.read(
                filesAt: urls, allowsBinary: allowsBinary, staging: staging, generation: generation)
            _ = self.apply(intake: resolved)
        }
    }

    /// Whether any URL points at a directory (a folder or OS package), via a
    /// cheap stat — gates the "Archiving folder…" transient before the off-main
    /// resolve.
    nonisolated private static func containsDirectory(_ urls: [URL]) -> Bool {
        urls.contains { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
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
                indicatorView.showTransientMessage(note, style: .warning)
            }
            Self.logger.info(
                "Took in pasteboard content (\(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
            )
            return true
        case .rejected(let message):
            indicatorView.showTransientMessage(message, style: .warning)
            Self.logger.info("Pasteboard intake rejected: \(message, privacy: .public)")
            return false
        case .pendingFiles:
            // Pending files must be resolved via read(filesAt:) (off the main
            // actor) before apply — reaching here is a programming error.
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

        let allowsBinary = service.supportsBinaryRepresentations
        let result = ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: allowsBinary)
        switch result {
        case .content:
            return apply(intake: result)
        case .pendingFiles(let urls):
            // Accept the drop now; resolve the files/folders off the main actor
            // (the dragging pasteboard was already consumed synchronously above).
            resolveAndApply(pendingFiles: urls, allowsBinary: allowsBinary)
            return true
        case .rejected:
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
    }

    /// Receives a promised file into a scratch directory, runs it through
    /// the shared file intake, and cleans the scratch copy up (the buffer
    /// keeps the bytes, not the file).
    private func receivePromisedFile(_ receiver: NSFilePromiseReceiver) {
        guard let service = instance.clipboardService else { return }
        let allowsBinary = service.supportsBinaryRepresentations

        indicatorView.showTransientMessage("Receiving dropped file…", style: .info)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaClipboardDrops-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            indicatorView.showTransientMessage("Couldn't receive the dropped file", style: .error)
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
                    self.indicatorView.showTransientMessage("Couldn't receive the dropped file", style: .error)
                    Self.logger.error(
                        "File promise receipt failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                guard !firstFileGate.taken else { return }
                firstFileGate.taken = true
                // Resolve off the main actor through the archive-aware overload so
                // a promised *folder* is archived just like a concrete file-URL
                // drag, instead of being silently rejected as "unreadable" (a
                // directory has no `.fileSize`). Still single-item — the gate above
                // takes only the first promised entry.
                let generation = self.stagingGeneration
                self.stagingGeneration += 1
                let staging = self.staging
                let resolved = await ClipboardPasteboardIntake.read(
                    filesAt: [url], allowsBinary: allowsBinary, staging: staging,
                    generation: generation)
                _ = self.apply(intake: resolved)
            }
        }
    }

    // MARK: - Responder-chain edit actions

    // Cover image/summary/empty-unfocused modes; in text mode the focused
    // NSTextView handles Cmd+V/Cmd+C natively (and pasting an image with the
    // editor focused does nothing — the Paste button is the affordance).
    @objc func paste(_ sender: Any?) {
        takeIn(pasteboard: .general)
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
            return !service.clipboardContent.isEmpty && !isCopyingToMac
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

        // Connection status leads; the content-type indicator is right-aligned
        // (flush right in the common case where the agent-action button is
        // hidden, sliding just left of it when an install/update prompt shows).
        let stack = NSStackView(views: [statusCircle, statusLabel, spacer, indicatorView, actionButton])
        stack.orientation = .horizontal
        stack.spacing = Spacing.small
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.alignment = .centerY

        return stack
    }
}

/// The narrow slice of `NSPasteboard` the "Copy to Mac" write path needs, so a
/// test can substitute a fake that forces `writeObjects` to fail.
///
/// `NSPasteboard` is a class cluster with no public initializer and can't be
/// subclassed, so its write can't be made to fail from a test. This write-only
/// seam (clear, an objects-write returning `Bool`, and a read-back for
/// assertions) is deliberately separate from the guest agent's richer
/// `Pasteboard` protocol, which also carries poll/read members the host write
/// path never uses. `NSPasteboard` satisfies all three requirements as-is.
protocol HostWritePasteboard: AnyObject {
    @discardableResult func clearContents() -> Int
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: HostWritePasteboard {}
