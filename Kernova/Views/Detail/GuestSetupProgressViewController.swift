import AppKit

/// Step-by-step progress UI for a guest setup — a macOS install
/// (download → install), or a Linux installer image (download → verify).
///
/// The steps come from the VM's ``GuestSetupState`` and are fixed for the run,
/// so the indicator is built once at `loadView`; the wording comes from the
/// ``GuestSetupDescriptor`` the router picks for the flow.
@MainActor
final class GuestSetupProgressViewController: NSViewController {
    private let instance: VMInstance
    private let descriptor: GuestSetupDescriptor
    private let onCancel: () -> Void
    private var observation: ObservationLoop?

    private let progressBar = NSProgressIndicator()
    private let detailLine1Label = NSTextField(labelWithString: "")
    private let detailLine2Label = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()

    /// Line 2 (speed/ETA) refreshes at most once a second; line 1 (bytes/%) and
    /// the progress bar track the smoother's raw ~10 Hz feed.
    private static let line2RefreshInterval: TimeInterval = 1.0
    private var lastLine2Refresh: TimeInterval = 0

    /// The views making up one row of the step indicator.
    @MainActor private struct StepRow {
        let circle = NSImageView()
        let label = NSTextField(labelWithString: "")
        let spinner = NSProgressIndicator()
        let check = NSImageView()
    }

    // Step indicator (present only for a flow with more than one step).
    private var stepRows: [StepRow] = []
    /// The vertical rules between consecutive rows; `connectors[i]` sits below
    /// `stepRows[i]`.
    private var connectors: [NSBox] = []

    init(
        instance: VMInstance,
        descriptor: GuestSetupDescriptor,
        onCancel: @escaping () -> Void
    ) {
        self.instance = instance
        self.descriptor = descriptor
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GuestSetupProgressViewController does not support NSCoder")
    }

    override func loadView() {
        let icon = NSImageView(image: Self.image(for: descriptor.icon))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let title = NSTextField(labelWithString: descriptor.title)
        title.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
        title.isSelectable = false

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let detailFont = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
        for label in [detailLine1Label, detailLine2Label] {
            label.font = detailFont
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.isSelectable = false
        }
        detailLine2Label.isHidden = true

        let detailStack = NSStackView(views: [detailLine1Label, detailLine2Label])
        detailStack.orientation = .vertical
        detailStack.alignment = .centerX
        detailStack.spacing = Spacing.hairline

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .push
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        var arranged: [NSView] = [icon, title]
        let state = instance.setupState
        if let state, state.showsStepIndicator {
            arranged.append(makeStepIndicator(for: state.steps))
        }
        arranged.append(progressBar)
        arranged.append(detailStack)
        arranged.append(cancelButton)

        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.major
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if observation == nil {
            observation = observeRecurring(
                track: { [weak self] in _ = self?.instance.setupState },
                apply: { [weak self] in self?.apply() }
            )
        }
        apply()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observation?.cancel()
        observation = nil
        stepRows.forEach { $0.spinner.stopAnimation(nil) }
    }

    private static func image(for icon: GuestSetupDescriptor.Icon) -> NSImage {
        switch icon {
        case .named(let name): NSImage(named: name) ?? NSImage()
        case .symbol(let symbol): .systemSymbol(symbol, accessibilityDescription: "")
        }
    }

    // MARK: - Step indicator construction

    private func makeStepIndicator(for steps: [SetupStep]) -> NSStackView {
        var arranged: [NSView] = []
        var rows: [NSView] = []
        for (index, step) in steps.enumerated() {
            if index > 0 { arranged.append(makeConnectorRow()) }
            let stepRow = StepRow()
            stepRow.label.stringValue = step.label
            stepRows.append(stepRow)
            let row = makeStepRow(stepRow)
            rows.append(row)
            arranged.append(row)
        }

        let indicator = NSStackView(views: arranged)
        indicator.orientation = .vertical
        indicator.alignment = .leading
        indicator.spacing = Spacing.none
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.widthAnchor.constraint(equalToConstant: 240).isActive = true
        for row in rows {
            row.widthAnchor.constraint(equalTo: indicator.widthAnchor).isActive = true
        }
        return indicator
    }

    private func makeConnectorRow() -> NSView {
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = .secondaryLabelColor.withAlphaComponent(0.3)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 2).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        connectors.append(line)

        // Indent the connector to sit under the 24pt circle's center.
        let connectorRow = NSStackView(views: [line])
        connectorRow.orientation = .horizontal
        connectorRow.alignment = .leading
        connectorRow.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 0)
        return connectorRow
    }

    private func makeStepRow(_ step: StepRow) -> NSView {
        step.circle.translatesAutoresizingMaskIntoConstraints = false
        step.circle.widthAnchor.constraint(equalToConstant: 24).isActive = true
        step.circle.heightAnchor.constraint(equalToConstant: 24).isActive = true
        step.circle.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 22, weight: .regular)

        step.label.font = Typography.body
        step.label.isSelectable = false

        step.spinner.style = .spinning
        step.spinner.controlSize = .small
        step.spinner.isIndeterminate = true
        step.spinner.translatesAutoresizingMaskIntoConstraints = false

        step.check.image = .systemSymbol("checkmark", accessibilityDescription: "Completed")
        step.check.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .caption1)
        step.check.contentTintColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [step.circle, step.label, spacer, step.spinner, step.check])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.relaxed
        return row
    }

    // MARK: - Refresh

    private func apply() {
        guard isViewLoaded, let state = instance.setupState, let step = state.currentStep else {
            return
        }

        applyStepStates(state)
        progressBar.doubleValue = state.progress.fraction
        refreshDetailLabels(
            for: state.progress, verb: descriptor.copy(for: step.id).detailVerb)
    }

    /// Refreshes the two subtitle labels.
    ///
    /// Line 2 (speed/ETA) is throttled to `line2RefreshInterval` so the smoothed
    /// figures don't flicker, but refreshes the instant it starts or stops
    /// applying so its appearance isn't delayed by a throttle window.
    private func refreshDetailLabels(for progress: SetupStepProgress, verb: String) {
        detailLine1Label.stringValue = Self.detailLine1(for: progress, verb: verb)

        let line2 = Self.detailLine2(for: progress)
        let visibilityChanged = detailLine2Label.isHidden == (line2 != nil)
        let now = ProcessInfo.processInfo.systemUptime
        if visibilityChanged || now - lastLine2Refresh >= Self.line2RefreshInterval {
            detailLine2Label.stringValue = line2 ?? ""
            detailLine2Label.isHidden = (line2 == nil)
            lastLine2Refresh = now
        }
    }

    private func applyStepStates(_ state: GuestSetupState) {
        for (index, row) in stepRows.enumerated() {
            applyStep(state.state(ofStepAt: index), number: index + 1, to: row)
        }
        for (index, connector) in connectors.enumerated() {
            connector.fillColor =
                state.state(ofStepAt: index) == .completed
                ? .controlAccentColor : .secondaryLabelColor.withAlphaComponent(0.3)
        }
    }

    private func applyStep(_ state: SetupStepState, number: Int, to row: StepRow) {
        switch state {
        case .completed:
            row.circle.image = .systemSymbol(
                "checkmark.circle.fill", accessibilityDescription: "Completed")
            row.circle.contentTintColor = .controlAccentColor
            row.label.textColor = .labelColor
            row.label.font = Typography.body
            row.spinner.stopAnimation(nil)
            row.spinner.isHidden = true
            row.check.isHidden = false
        case .active:
            row.circle.image = .systemSymbol("\(number).circle.fill", accessibilityDescription: "")
            row.circle.contentTintColor = .controlAccentColor
            row.label.textColor = .labelColor
            row.label.font = .systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium)
            row.spinner.isHidden = false
            row.spinner.startAnimation(nil)
            row.check.isHidden = true
        case .pending:
            row.circle.image = .systemSymbol("\(number).circle", accessibilityDescription: "")
            row.circle.contentTintColor = .secondaryLabelColor
            row.label.textColor = .secondaryLabelColor
            row.label.font = Typography.body
            row.spinner.stopAnimation(nil)
            row.spinner.isHidden = true
            row.check.isHidden = true
        }
    }

    /// Builds subtitle line 1 — the byte/percent progress line — for a step
    /// whose work `verb` names.
    ///
    /// Assembled from figure-space-padded fixed-width fields so it holds a stable
    /// horizontal position as values update.
    nonisolated static func detailLine1(for progress: SetupStepProgress, verb: String) -> String {
        switch progress {
        case .download(let download):
            let written = DataFormatters.formatBytesFixedWidth(UInt64(max(0, download.bytesWritten)))
            let total = DataFormatters.formatBytesFixedWidth(UInt64(max(0, download.totalBytes)))
            let pct = String(format: "%3d", Int(download.fraction * 100))
                .replacingOccurrences(of: " ", with: "\u{2007}")
            return "\(verb):\u{2007}\(written) / \(total) — \(pct)%"
        case .fraction(let value):
            let pct = String(format: "%3d", Int(value * 100))
                .replacingOccurrences(of: " ", with: "\u{2007}")
            return "\(verb):\u{2007}\(pct)%"
        }
    }

    /// Builds subtitle line 2 — the speed/ETA line — or `nil` when it doesn't
    /// apply (a step that only reports a fraction, or before the first non-zero
    /// speed sample).
    ///
    /// The constant-glyph `H:MM:SS` ETA falls back to a same-width dash
    /// placeholder (rather than vanishing) so the line keeps a constant width
    /// whenever it is shown.
    nonisolated static func detailLine2(for progress: SetupStepProgress) -> String? {
        guard case .download(let download) = progress, download.bytesPerSecond > 0 else {
            return nil
        }
        let speed = DataFormatters.formatSpeed(download.bytesPerSecond)
        let eta =
            DataFormatters.formatETA(
                remainingBytes: download.totalBytes - download.bytesWritten,
                bytesPerSecond: download.bytesPerSecond) ?? DataFormatters.etaUnknownPlaceholder
        return "\(speed) — \(eta)\u{2007}remaining"
    }

    // MARK: - Cancel

    @objc private func cancelTapped() {
        guard let window = view.window, let step = instance.setupState?.currentStep else { return }
        let prompt = descriptor.copy(for: step.id).cancelPrompt
        let config = AlertConfiguration(
            title: prompt.title,
            message: prompt.message,
            buttons: [
                AlertButton(prompt.confirmTitle, role: .default) { [weak self] in
                    self?.onCancel()
                },
                AlertButton(prompt.dismissTitle, role: .cancel),
            ])
        presentSheetAlert(config, in: window)
    }
}
