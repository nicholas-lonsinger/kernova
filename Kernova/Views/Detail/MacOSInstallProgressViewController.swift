import AppKit

/// Two-step macOS install progress UI (download → install).
///
/// AppKit reimplementation of the former SwiftUI `MacOSInstallProgressView`.
/// Observes the instance's `installState`; when the install includes a download
/// step it shows numbered step indicators with a connector, otherwise just the
/// install progress bar. The Cancel button confirms via a sheet alert (download
/// resumes next start; install restarts from the cached image).
@MainActor
final class MacOSInstallProgressViewController: NSViewController {
    private let instance: VMInstance
    private let onCancel: () -> Void
    private var observation: ObservationLoop?

    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton()

    // Step indicator (present only when the install has a download step).
    private var stepIndicator: NSStackView?
    private let downloadCircle = NSImageView()
    private let downloadLabel = NSTextField(labelWithString: "Download")
    private let downloadSpinner = NSProgressIndicator()
    private let downloadCheck = NSImageView()
    private let installCircle = NSImageView()
    private let installLabel = NSTextField(labelWithString: "Install")
    private let installSpinner = NSProgressIndicator()
    private let installCheck = NSImageView()
    private var connector: NSBox?

    private enum StepState { case pending, active, completed }

    init(instance: VMInstance, onCancel: @escaping () -> Void) {
        self.instance = instance
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MacOSInstallProgressViewController does not support NSCoder")
    }

    override func loadView() {
        let icon = NSImageView(image: NSImage(named: NSImage.computerName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let title = NSTextField(labelWithString: "Installing macOS")
        title.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
        title.isSelectable = false

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 320).isActive = true

        detailLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        detailLabel.isSelectable = false

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        var arranged: [NSView] = [icon, title]
        if instance.installState?.hasDownloadStep == true {
            let indicator = makeStepIndicator()
            stepIndicator = indicator
            arranged.append(indicator)
        }
        arranged.append(progressBar)
        arranged.append(detailLabel)
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
                track: { [weak self] in _ = self?.instance.installState },
                apply: { [weak self] in self?.apply() }
            )
        }
        apply()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observation?.cancel()
        observation = nil
        downloadSpinner.stopAnimation(nil)
        installSpinner.stopAnimation(nil)
    }

    // MARK: - Step indicator construction

    private func makeStepIndicator() -> NSStackView {
        let downloadRow = makeStepRow(
            circle: downloadCircle, label: downloadLabel, spinner: downloadSpinner,
            check: downloadCheck)
        let installRow = makeStepRow(
            circle: installCircle, label: installLabel, spinner: installSpinner,
            check: installCheck)

        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = .secondaryLabelColor.withAlphaComponent(0.3)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 2).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        connector = line

        // Indent the connector to sit under the 24pt circle's center.
        let connectorRow = NSStackView(views: [line])
        connectorRow.orientation = .horizontal
        connectorRow.alignment = .leading
        connectorRow.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 0)

        let indicator = NSStackView(views: [downloadRow, connectorRow, installRow])
        indicator.orientation = .vertical
        indicator.alignment = .leading
        indicator.spacing = Spacing.none
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.widthAnchor.constraint(equalToConstant: 240).isActive = true
        downloadRow.widthAnchor.constraint(equalTo: indicator.widthAnchor).isActive = true
        installRow.widthAnchor.constraint(equalTo: indicator.widthAnchor).isActive = true
        return indicator
    }

    private func makeStepRow(
        circle: NSImageView, label: NSTextField, spinner: NSProgressIndicator,
        check: NSImageView
    ) -> NSView {
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.widthAnchor.constraint(equalToConstant: 24).isActive = true
        circle.heightAnchor.constraint(equalToConstant: 24).isActive = true
        circle.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)

        label.font = Typography.body
        label.isSelectable = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        check.image = .systemSymbol("checkmark", accessibilityDescription: "Completed")
        check.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .caption1)
        check.contentTintColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [circle, label, spacer, spinner, check])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.relaxed
        return row
    }

    // MARK: - Refresh

    private func apply() {
        guard isViewLoaded, let state = instance.installState else { return }

        if state.hasDownloadStep {
            applyStepStates(state)
        }

        switch state.currentPhase {
        case .downloading(let download):
            progressBar.doubleValue = download.fraction
        case .installing(let progress):
            progressBar.doubleValue = progress
        }
        detailLabel.stringValue = Self.detailText(for: state.currentPhase)
    }

    private func applyStepStates(_ state: MacOSInstallState) {
        let downloadState = downloadStepState(state)
        let installState = installStepState(state)
        applyStep(
            downloadState, number: 1, circle: downloadCircle, label: downloadLabel,
            spinner: downloadSpinner, check: downloadCheck)
        applyStep(
            installState, number: 2, circle: installCircle, label: installLabel,
            spinner: installSpinner, check: installCheck)
        connector?.fillColor =
            state.downloadCompleted ? .controlAccentColor : .secondaryLabelColor.withAlphaComponent(0.3)
    }

    private func applyStep(
        _ state: StepState, number: Int, circle: NSImageView, label: NSTextField,
        spinner: NSProgressIndicator, check: NSImageView
    ) {
        switch state {
        case .completed:
            circle.image = .systemSymbol("checkmark.circle.fill", accessibilityDescription: "Completed")
            circle.contentTintColor = .controlAccentColor
            label.textColor = .labelColor
            label.font = Typography.body
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            check.isHidden = false
        case .active:
            circle.image = .systemSymbol("\(number).circle.fill", accessibilityDescription: "")
            circle.contentTintColor = .controlAccentColor
            label.textColor = .labelColor
            label.font = .systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium)
            spinner.isHidden = false
            spinner.startAnimation(nil)
            check.isHidden = true
        case .pending:
            circle.image = .systemSymbol("\(number).circle", accessibilityDescription: "")
            circle.contentTintColor = .secondaryLabelColor
            label.textColor = .secondaryLabelColor
            label.font = Typography.body
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            check.isHidden = true
        }
    }

    private func downloadStepState(_ state: MacOSInstallState) -> StepState {
        if state.downloadCompleted { return .completed }
        if case .downloading = state.currentPhase { return .active }
        return .pending
    }

    private func installStepState(_ state: MacOSInstallState) -> StepState {
        if case .installing = state.currentPhase {
            return state.downloadCompleted ? .active : .pending
        }
        return .pending
    }

    /// Builds the subtitle text for a phase.
    ///
    /// Both lines are assembled from fixed-width pieces (figure-space-padded
    /// byte/percent fields and the constant-glyph `H:MM:SS` ETA) so the label
    /// holds a stable horizontal position as values update — see #555. Pure and
    /// `nonisolated` so it can be exercised directly by the width-stability tests.
    nonisolated static func detailText(for phase: MacOSInstallPhase) -> String {
        switch phase {
        case .downloading(let download):
            return downloadDetailText(download)
        case .installing(let progress):
            let pct = String(format: "%3d", Int(progress * 100))
                .replacingOccurrences(of: " ", with: "\u{2007}")
            return "Installing macOS:\u{2007}\(pct)%"
        }
    }

    nonisolated static func downloadDetailText(_ download: DownloadProgress) -> String {
        let written = DataFormatters.formatBytesFixedWidth(UInt64(max(0, download.bytesWritten)))
        let total = DataFormatters.formatBytesFixedWidth(UInt64(max(0, download.totalBytes)))
        let pct = String(format: "%3d", Int(download.fraction * 100))
            .replacingOccurrences(of: " ", with: "\u{2007}")
        var text = "Downloading:\u{2007}\(written) / \(total) — \(pct)%"
        if download.bytesPerSecond > 0 {
            let speed = DataFormatters.formatSpeed(download.bytesPerSecond)
            // Fall back to a same-width dash placeholder (rather than dropping
            // the ETA slot) so line 2 keeps a constant width while it is shown.
            let eta =
                DataFormatters.formatETA(
                    remainingBytes: download.totalBytes - download.bytesWritten,
                    bytesPerSecond: download.bytesPerSecond) ?? DataFormatters.etaUnknownPlaceholder
            text += "\n\(speed) — \(eta)\u{2007}remaining"
        }
        return text
    }

    // MARK: - Cancel

    @objc private func cancelTapped() {
        guard let window = view.window else { return }
        let downloadPhase: Bool
        if case .downloading = instance.installState?.currentPhase {
            downloadPhase = true
        } else {
            downloadPhase = false
        }
        let config = AlertConfiguration(
            title: downloadPhase ? "Cancel Download?" : "Cancel Installation?",
            message: downloadPhase
                ? "The download progress will be saved and resumed the next time you start the virtual machine."
                : "The installation will restart from the beginning the next time you start the virtual machine. The downloaded macOS image is cached, so you won't need to download it again.",
            buttons: [
                AlertButton(downloadPhase ? "Cancel Download" : "Cancel Installation", role: .default) {
                    [weak self] in self?.onCancel()
                },
                AlertButton(downloadPhase ? "Keep Downloading" : "Keep Installing", role: .cancel),
            ])
        presentSheetAlert(config, in: window)
    }
}
