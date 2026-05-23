import AppKit

/// AppKit content view controller for the detail-pane "console" placeholder.
///
/// Shows a centered empty-state (icon + title + description + optional action
/// button) for the non-inline display states — `Fullscreen`, `Popped Out`,
/// `Suspended` (cold-paused), and `No Display` — and falls back to an inert
/// black fill while a live VM display is layered on top by
/// `DetailContainerViewController`.
///
/// Observes `VMInstance.displayMode`, `isColdPaused`, and `virtualMachine` via
/// `observeRecurring` and recomputes the visible state in `apply()`.
@MainActor
final class VMConsoleContentViewController: NSViewController {
    private var instance: VMInstance
    private let emptyState = ConsoleEmptyStateView()
    private var observation: ObservationLoop?

    init(instance: VMInstance) {
        self.instance = instance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMConsoleContentViewController does not support NSCoder")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyState.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        apply()
        observeInstance()
    }

    // MARK: - Reconfiguration

    /// Re-bind to a different `VMInstance` (e.g. the user selected a new VM).
    ///
    /// No-op when the instance identity is unchanged. Restarts observation so
    /// the controller stops tracking the previous instance's properties.
    func reconfigure(instance newInstance: VMInstance) {
        guard newInstance !== instance else { return }
        instance = newInstance
        observation?.cancel()
        observation = nil
        if isViewLoaded {
            apply()
            observeInstance()
        }
    }

    // MARK: - Observation

    private func observeInstance() {
        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.displayMode
                _ = self.instance.isColdPaused
                _ = self.instance.virtualMachine
            },
            apply: { [weak self] in
                self?.apply()
            }
        )
    }

    // MARK: - State

    private enum ConsoleState {
        case fullscreen
        case poppedOut
        case suspended
        case live
        case noDisplay
    }

    private func consoleState() -> ConsoleState {
        switch instance.displayMode {
        case .fullscreen: return .fullscreen
        case .popOut: return .poppedOut
        case .inline:
            if instance.isColdPaused { return .suspended }
            if instance.virtualMachine != nil { return .live }
            return .noDisplay
        }
    }

    private func apply() {
        switch consoleState() {
        case .fullscreen:
            emptyState.isHidden = false
            emptyState.configure(
                symbolName: "arrow.up.left.and.arrow.down.right",
                title: "Fullscreen",
                description: "The virtual machine display is in fullscreen mode.",
                action: ConsoleEmptyStateView.Action(
                    title: "Exit Fullscreen",
                    selector: #selector(AppDelegate.toggleFullscreen(_:))
                )
            )
        case .poppedOut:
            emptyState.isHidden = false
            emptyState.configure(
                symbolName: "pip.exit",
                title: "Popped Out",
                description: "The virtual machine display is in a separate window.",
                action: ConsoleEmptyStateView.Action(
                    title: "Pop In",
                    selector: #selector(AppDelegate.togglePopOut(_:))
                )
            )
        case .suspended:
            emptyState.isHidden = false
            emptyState.configure(
                symbolName: "pause.circle",
                title: "Suspended",
                description: "This virtual machine's state is saved to disk. Resume to continue.",
                action: nil
            )
        case .noDisplay:
            emptyState.isHidden = false
            emptyState.configure(
                symbolName: "display",
                title: "No Display",
                description: "The virtual machine display is not available.",
                action: nil
            )
        case .live:
            // The AppKit VM display covers this layer in DetailContainerViewController.
            // Hide the placeholder so the black background is fully inert.
            emptyState.isHidden = true
        }
    }
}

// MARK: - ConsoleEmptyStateView

/// AppKit empty-state placeholder: a centered SF Symbol, title, description,
/// and optional action button.
///
/// Approximates SwiftUI's `ContentUnavailableView` styling without inheriting
/// any of its declarative machinery. Action buttons dispatch through the
/// responder chain via `NSApp.sendAction(_:to:from:)`, matching how the
/// SwiftUI predecessor reached the `AppDelegate` selectors.
@MainActor
private final class ConsoleEmptyStateView: NSView {
    struct Action {
        let title: String
        let selector: Selector
    }

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let stack = NSStackView()

    private var currentSelector: Selector?

    /// Soft cap so multi-line descriptions wrap reasonably instead of stretching
    /// to the full detail-pane width.
    private static let maxContentWidth: CGFloat = 360

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 6, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        descriptionLabel.font = NSFont.preferredFont(forTextStyle: .body)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.preferredMaxLayoutWidth = Self.maxContentWidth
        descriptionLabel.lineBreakMode = .byWordWrapping

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(actionButtonClicked(_:))

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([imageView, titleLabel, descriptionLabel, actionButton], in: .leading)
        // Tighten the gap between the icon and title so the cluster reads as a unit.
        stack.setCustomSpacing(8, after: imageView)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(16, after: descriptionLabel)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxContentWidth),
            imageView.widthAnchor.constraint(equalToConstant: 52),
            imageView.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConsoleEmptyStateView does not support NSCoder")
    }

    func configure(symbolName: String, title: String, description: String, action: Action?) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        guard
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
        else {
            assertionFailure("Missing SF Symbol '\(symbolName)' for console empty state")
            imageView.image = nil
            titleLabel.stringValue = title
            descriptionLabel.stringValue = description
            return
        }
        imageView.image = symbol
        titleLabel.stringValue = title
        descriptionLabel.stringValue = description

        if let action {
            actionButton.title = action.title
            currentSelector = action.selector
            actionButton.isHidden = false
        } else {
            currentSelector = nil
            actionButton.isHidden = true
        }
    }

    @objc private func actionButtonClicked(_ sender: Any?) {
        guard let selector = currentSelector else { return }
        // Route through the responder chain so AppDelegate (or whichever
        // responder handles the selector) receives the action — same dispatch
        // strategy the SwiftUI predecessor used.
        NSApp.sendAction(selector, to: nil, from: sender)
    }
}
