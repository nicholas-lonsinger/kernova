import AppKit
import os

/// AppKit content view controller for the detail-pane "console" placeholder.
///
/// Shows a centered empty-state (icon + title + description + optional action
/// buttons) for the non-inline display states — `Fullscreen`, `Popped Out`,
/// `Display Closed` (running headless), `Suspended` (cold-paused), and
/// `No Display` — and falls back to an inert black fill while a live VM
/// display is layered on top by `DetailContainerViewController`.
///
/// Observes `VMInstance.displayMode`, `isColdPaused`, and `virtualMachine` via
/// `observeRecurring` and recomputes the visible state in `apply()`.
@MainActor
final class VMDisplayPlaceholderContentViewController: NSViewController {
    private var instance: VMInstance
    private let emptyState = DisplayPlaceholderEmptyStateView()
    private var observation: ObservationLoop?

    private static let logger = Logger(
        subsystem: "app.kernova", category: "VMDisplayPlaceholderVC"
    )

    init(instance: VMInstance) {
        self.instance = instance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMDisplayPlaceholderContentViewController does not support NSCoder")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()
        // Layer-backed so `apply()` can paint a black fill for the `.live`
        // case where the AppKit VM display layer is expected to cover this
        // view. Background is set per state in `apply()` — never here.
        container.wantsLayer = true

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
        Self.logger.debug(
            "Reconfigured to instance '\(newInstance.name, privacy: .public)'"
        )
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
        case displayClosed
        case suspended
        case live
        case noDisplay
    }

    private func consoleState() -> ConsoleState {
        switch instance.displayMode {
        case .fullscreen: return .fullscreen
        case .popOut: return .poppedOut
        case .hidden: return .displayClosed
        case .inline:
            if instance.isColdPaused { return .suspended }
            if instance.virtualMachine != nil { return .live }
            return .noDisplay
        }
    }

    private func apply() {
        let state = consoleState()
        // Paint black only for `.live`: that case is meant to sit underneath
        // the AppKit VM display layer in `DetailContainerViewController`, so a
        // black fill is the right inert appearance. For every other state we
        // render the empty-state on the system background like the SwiftUI
        // `ContentUnavailableView` predecessor did — otherwise `.labelColor`
        // text becomes unreadable on a black panel in Light Appearance.
        view.layer?.backgroundColor = (state == .live) ? NSColor.black.cgColor : nil

        switch state {
        case .fullscreen:
            emptyState.isHidden = false
            emptyState.configure(
                symbolName: "arrow.up.left.and.arrow.down.right",
                title: "Fullscreen",
                description: "The virtual machine display is in fullscreen mode.",
                actions: [
                    DisplayPlaceholderEmptyStateView.Action(
                        title: "Show Display",
                        selector: #selector(AppDelegate.showDisplayWindow(_:))
                    ),
                    DisplayPlaceholderEmptyStateView.Action(
                        title: "Exit Fullscreen",
                        selector: #selector(AppDelegate.toggleFullscreen(_:))
                    ),
                ]
            )
        case .poppedOut:
            emptyState.isHidden = false
            emptyState.configure(
                symbolName: "pip.exit",
                title: "Popped Out",
                description: "The virtual machine display is in a separate window.",
                actions: [
                    DisplayPlaceholderEmptyStateView.Action(
                        title: "Show Display",
                        selector: #selector(AppDelegate.showDisplayWindow(_:))
                    ),
                    DisplayPlaceholderEmptyStateView.Action(
                        title: "Pop In",
                        selector: #selector(AppDelegate.togglePopOut(_:))
                    ),
                ]
            )
        case .displayClosed:
            emptyState.isHidden = false
            emptyState.configure(
                symbolName: "eye.slash",
                title: "Display Closed",
                description: "The virtual machine is running without a display window.",
                actions: [
                    DisplayPlaceholderEmptyStateView.Action(
                        title: "Show Display",
                        selector: #selector(AppDelegate.showDisplayWindow(_:))
                    ),
                    DisplayPlaceholderEmptyStateView.Action(
                        title: "Pop In",
                        selector: #selector(AppDelegate.togglePopOut(_:))
                    ),
                ]
            )
        case .suspended:
            emptyState.isHidden = false
            emptyState.configure(
                symbolName: "pause.circle",
                title: "Suspended",
                description: "This virtual machine's state is saved to disk. Resume to continue.",
                actions: []
            )
        case .noDisplay:
            emptyState.isHidden = false
            emptyState.configure(
                symbolName: "display",
                title: "No Display",
                description: "The virtual machine display is not available.",
                actions: []
            )
        case .live:
            emptyState.isHidden = true
        }
    }
}

// MARK: - DisplayPlaceholderEmptyStateView

/// AppKit empty-state placeholder: a centered SF Symbol, title, description,
/// and an optional row of action buttons.
///
/// Approximates SwiftUI's `ContentUnavailableView` styling without inheriting
/// any of its declarative machinery. Action buttons use `target = nil` so
/// `NSControl`'s built-in responder-chain dispatch routes through `NSApp`
/// to the configured selector (matching how the SwiftUI predecessor reached
/// `AppDelegate.toggleFullscreen(_:)` / `togglePopOut(_:)`).
@MainActor
private final class DisplayPlaceholderEmptyStateView: NSView {
    struct Action {
        let title: String
        let selector: Selector
    }

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let buttonRow = NSStackView()
    private let stack = NSStackView()

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

        descriptionLabel.font = Typography.body
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.preferredMaxLayoutWidth = Self.maxContentWidth
        descriptionLabel.lineBreakMode = .byWordWrapping

        buttonRow.orientation = .horizontal
        buttonRow.spacing = Spacing.standard

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([imageView, titleLabel, descriptionLabel, buttonRow], in: .top)
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
        fatalError("DisplayPlaceholderEmptyStateView does not support NSCoder")
    }

    func configure(symbolName: String, title: String, description: String, actions: [Action]) {
        // `NSImage.systemSymbol` already logs at `.fault` and asserts on miss;
        // no need to re-implement the defensive unwrap here.
        imageView.image = NSImage.systemSymbol(symbolName, accessibilityDescription: "")
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 44, weight: .regular))
        titleLabel.stringValue = title
        descriptionLabel.stringValue = description

        buttonRow.setViews(
            actions.map { action in
                let button = NSButton(title: action.title, target: nil, action: action.selector)
                button.bezelStyle = .rounded
                button.controlSize = .regular
                return button
            },
            in: .center
        )
        buttonRow.isHidden = actions.isEmpty
    }
}
