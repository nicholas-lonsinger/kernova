import AppKit

/// Placeholder content shown behind the AppKit `VMDisplayBackingView` layer
/// when a VM with an active display is in a state where the inline display
/// isn't visible: popped out, fullscreen, suspended/cold-paused, or no
/// virtual machine assigned.
///
/// Replaces the SwiftUI `VMConsoleView`. The inline branch draws an inert
/// black background — the AppKit `VMDisplayBackingView` in
/// `DetailContainerViewController` is what the user actually sees there.
@MainActor
final class ConsolePlaceholderViewController: NSViewController {
    private let instance: VMInstance
    private let container = NSView()
    private var currentChild: NSView?
    private var observation: ObservationLoop?

    init(instance: VMInstance) {
        self.instance = instance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConsolePlaceholderViewController does not support NSCoder")
    }

    override func loadView() {
        container.wantsLayer = true
        view = container

        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.displayMode
                _ = self.instance.isColdPaused
                _ = self.instance.virtualMachine
            },
            apply: { [weak self] in self?.refresh() }
        )
        refresh()
    }

    private func refresh() {
        let next = buildPlaceholder()
        if let current = currentChild {
            current.removeFromSuperview()
        }
        container.addFullSizeSubview(next)
        currentChild = next
    }

    private func buildPlaceholder() -> NSView {
        switch instance.displayMode {
        case .fullscreen:
            return makePlaceholder(
                symbol: "arrow.up.left.and.arrow.down.right",
                title: "Fullscreen",
                subtitle: "The virtual machine display is in fullscreen mode.",
                buttonTitle: "Exit Fullscreen",
                buttonAction: #selector(AppDelegate.toggleFullscreen(_:))
            )
        case .popOut:
            return makePlaceholder(
                symbol: "pip.exit",
                title: "Popped Out",
                subtitle: "The virtual machine display is in a separate window.",
                buttonTitle: "Pop In",
                buttonAction: #selector(AppDelegate.togglePopOut(_:))
            )
        default:
            break
        }

        if instance.isColdPaused {
            return makePlaceholder(
                symbol: "pause.circle",
                title: "Suspended",
                subtitle: "This virtual machine's state is saved to disk. Resume to continue.",
                buttonTitle: nil,
                buttonAction: nil
            )
        }

        if instance.virtualMachine != nil {
            // Inert black background; the AppKit display backing view covers it.
            let black = NSView()
            black.wantsLayer = true
            black.layer?.backgroundColor = NSColor.black.cgColor
            return black
        }

        return makePlaceholder(
            symbol: "display",
            title: "No Display",
            subtitle: "The virtual machine display is not available.",
            buttonTitle: nil,
            buttonAction: nil
        )
    }

    private func makePlaceholder(
        symbol: String,
        title: String,
        subtitle: String,
        buttonTitle: String?,
        buttonAction: Selector?
    ) -> NSView {
        let icon = NSImageView(image: .systemSymbol(symbol, accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        var subviews: [NSView] = [icon, titleLabel, subtitleLabel]
        if let buttonTitle, let buttonAction {
            let button = NSButton(title: buttonTitle, target: nil, action: buttonAction)
            button.bezelStyle = .rounded
            subviews.append(button)
        }

        let stack = NSStackView(views: subviews)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        return wrapper
    }
}
