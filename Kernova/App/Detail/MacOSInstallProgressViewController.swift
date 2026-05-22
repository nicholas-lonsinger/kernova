import AppKit

/// Two-step progress UI for macOS installation (download → install).
///
/// Observes the install state on the VM instance and re-renders the active
/// step indicator, progress bar, and detail text. The cancel button
/// presents a confirmation alert via ``AlertPresenter`` and dispatches to
/// the library view model on confirm.
@MainActor
final class MacOSInstallProgressViewController: NSViewController {
    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel

    private let titleLabel = NSTextField(labelWithString: "Installing macOS")
    private let downloadRow = StepRowView(number: 1, label: "Download")
    private let installRow = StepRowView(number: 2, label: "Install")
    private let connector = NSView()
    private let stepStack = NSStackView()
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    private let secondaryDetailLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var observation: ObservationLoop?

    init(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MacOSInstallProgressViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let icon = NSImageView(image: NSImage(named: NSImage.computerName) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
        ])

        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.alignment = .center

        connector.wantsLayer = true
        connector.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        connector.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            connector.widthAnchor.constraint(equalToConstant: 2),
            connector.heightAnchor.constraint(equalToConstant: 18),
        ])
        // Vertical line aligned under the leading edge of the step circle
        let connectorContainer = NSView()
        connectorContainer.translatesAutoresizingMaskIntoConstraints = false
        connectorContainer.addSubview(connector)
        NSLayoutConstraint.activate([
            connector.leadingAnchor.constraint(equalTo: connectorContainer.leadingAnchor, constant: 11),
            connector.topAnchor.constraint(equalTo: connectorContainer.topAnchor),
            connector.bottomAnchor.constraint(equalTo: connectorContainer.bottomAnchor),
            connectorContainer.heightAnchor.constraint(equalToConstant: 18),
        ])

        stepStack.orientation = .vertical
        stepStack.spacing = 0
        stepStack.alignment = .leading
        stepStack.setViews([downloadRow, connectorContainer, installRow], in: .leading)
        stepStack.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .subheadline).monospaced
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        secondaryDetailLabel.font = .preferredFont(forTextStyle: .subheadline).monospaced
        secondaryDetailLabel.textColor = .secondaryLabelColor
        secondaryDetailLabel.alignment = .center

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))

        let stack = NSStackView(views: [
            icon, titleLabel, stepStack, progressBar, detailLabel, secondaryDetailLabel, cancelButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 400),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = container

        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.installState
                _ = self.instance.installState?.currentPhase
                _ = self.instance.installState?.downloadCompleted
            },
            apply: { [weak self] in self?.refresh() }
        )
        refresh()
    }

    // MARK: - Refresh

    private func refresh() {
        guard let installState = instance.installState else {
            stepStack.isHidden = true
            progressBar.doubleValue = 0
            detailLabel.stringValue = ""
            secondaryDetailLabel.stringValue = ""
            return
        }

        stepStack.isHidden = !installState.hasDownloadStep

        let downloadState = stepStateForDownload(installState)
        let installStateValue = stepStateForInstall(installState)
        downloadRow.apply(state: downloadState)
        installRow.apply(state: installStateValue)
        connector.layer?.backgroundColor =
            installState.downloadCompleted
            ? NSColor.controlAccentColor.cgColor
            : NSColor.tertiaryLabelColor.cgColor

        switch installState.currentPhase {
        case .downloading(let dl):
            progressBar.doubleValue = dl.fraction
            let written = DataFormatters.formatBytesFixedWidth(UInt64(dl.bytesWritten))
            let total = DataFormatters.formatBytesFixedWidth(UInt64(dl.totalBytes))
            let pct = String(format: "%3d", Int(dl.fraction * 100))
                .replacingOccurrences(of: " ", with: "\u{2007}")
            detailLabel.stringValue = "Downloading:\u{2007}\(written) / \(total) — \(pct)%"
            if dl.bytesPerSecond > 0 {
                let speed = DataFormatters.formatSpeed(dl.bytesPerSecond)
                if let eta = DataFormatters.formatETA(
                    remainingBytes: dl.totalBytes - dl.bytesWritten,
                    bytesPerSecond: dl.bytesPerSecond
                ) {
                    secondaryDetailLabel.stringValue = "\(speed) — \(eta)\u{2007}remaining"
                } else {
                    secondaryDetailLabel.stringValue = speed
                }
            } else {
                secondaryDetailLabel.stringValue = ""
            }
        case .installing(let progress):
            progressBar.doubleValue = progress
            detailLabel.stringValue = "Installing macOS: \(Int(progress * 100))%"
            secondaryDetailLabel.stringValue = ""
        }
    }

    private func stepStateForDownload(_ state: MacOSInstallState) -> StepRowView.State {
        if state.downloadCompleted { return .completed }
        if case .downloading = state.currentPhase { return .active }
        return .pending
    }

    private func stepStateForInstall(_ state: MacOSInstallState) -> StepRowView.State {
        if case .installing = state.currentPhase {
            return state.downloadCompleted ? .active : .pending
        }
        return .pending
    }

    // MARK: - Cancel

    @objc private func cancelTapped(_ sender: Any?) {
        guard let window = view.window else { return }
        guard let installState = instance.installState else { return }

        let isDownloadPhase: Bool = {
            if case .downloading = installState.currentPhase { return true }
            return false
        }()

        let title = isDownloadPhase ? "Cancel Download?" : "Cancel Installation?"
        let confirmLabel = isDownloadPhase ? "Cancel Download" : "Cancel Installation"
        let dismissLabel = isDownloadPhase ? "Keep Downloading" : "Keep Installing"
        let message: String =
            isDownloadPhase
            ? "The download progress will be saved and resumed the next time you start the virtual machine."
            : "The installation will restart from the beginning the next time you start the virtual machine. The downloaded macOS image is cached, so you won't need to download it again."

        AlertPresenter.present(
            in: window,
            title: title,
            message: message,
            style: .warning,
            buttons: [.default(confirmLabel), AlertButton(title: dismissLabel, role: .cancel)]
        ) { [weak self] index in
            guard let self, index == 0 else { return }
            self.viewModel.cancelInstallation(self.instance)
        }
    }
}

// MARK: - Step row

@MainActor
private final class StepRowView: NSStackView {
    enum State { case pending, active, completed }

    private let circle: NSView
    private let numberLabel: NSTextField
    private let checkmark: NSImageView
    private let labelView: NSTextField
    private let trailingProgress: NSProgressIndicator
    private let trailingCheck: NSImageView

    init(number: Int, label: String) {
        self.circle = NSView()
        self.numberLabel = NSTextField(labelWithString: "\(number)")
        self.checkmark = NSImageView(
            image: .systemSymbol("checkmark", accessibilityDescription: "")
        )
        self.labelView = NSTextField(labelWithString: label)
        self.trailingProgress = NSProgressIndicator()
        self.trailingCheck = NSImageView(
            image: .systemSymbol("checkmark", accessibilityDescription: "")
        )
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10

        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.wantsLayer = true
        circle.layer?.cornerRadius = 12
        circle.layer?.borderWidth = 1.5
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 24),
            circle.heightAnchor.constraint(equalToConstant: 24),
        ])

        numberLabel.font = .preferredFont(forTextStyle: .caption2)
        numberLabel.alignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(numberLabel)
        NSLayoutConstraint.activate([
            numberLabel.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])

        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.contentTintColor = .white
        circle.addSubview(checkmark)
        NSLayoutConstraint.activate([
            checkmark.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            checkmark.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
        checkmark.isHidden = true

        trailingProgress.style = .spinning
        trailingProgress.controlSize = .small
        trailingProgress.isIndeterminate = true
        trailingProgress.isHidden = true

        trailingCheck.contentTintColor = .secondaryLabelColor
        trailingCheck.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        setViews([circle, labelView, spacer, trailingProgress, trailingCheck], in: .leading)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StepRowView does not support NSCoder")
    }

    func apply(state: State) {
        switch state {
        case .pending:
            circle.layer?.backgroundColor = NSColor.clear.cgColor
            circle.layer?.borderColor = NSColor.secondaryLabelColor.cgColor
            numberLabel.isHidden = false
            numberLabel.textColor = .secondaryLabelColor
            checkmark.isHidden = true
            labelView.font = .preferredFont(forTextStyle: .body)
            labelView.textColor = .secondaryLabelColor
            trailingProgress.stopAnimation(nil)
            trailingProgress.isHidden = true
            trailingCheck.isHidden = true
        case .active:
            circle.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            circle.layer?.borderColor = NSColor.clear.cgColor
            numberLabel.isHidden = false
            numberLabel.textColor = .white
            checkmark.isHidden = true
            labelView.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            labelView.textColor = .labelColor
            trailingProgress.isHidden = false
            trailingProgress.startAnimation(nil)
            trailingCheck.isHidden = true
        case .completed:
            circle.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            circle.layer?.borderColor = NSColor.clear.cgColor
            numberLabel.isHidden = true
            checkmark.isHidden = false
            labelView.font = .preferredFont(forTextStyle: .body)
            labelView.textColor = .labelColor
            trailingProgress.stopAnimation(nil)
            trailingProgress.isHidden = true
            trailingCheck.isHidden = false
        }
    }
}

private extension NSFont {
    /// Monospaced-digit variant of the receiver.
    ///
    /// Used for fixed-width progress numerals so the label doesn't jitter as
    /// digits change.
    var monospaced: NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
