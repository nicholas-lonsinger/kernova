import AppKit

/// An error callout: `content`, which a click anywhere on dismisses, and which
/// VoiceOver reaches as one button labelled `label` that dismisses it when
/// pressed.
///
/// The click is the content's only one, so content with controls of its own
/// does not go here.
@MainActor
final class ClickToDismissCalloutController: NSViewController {
    private let content: NSViewController
    private let label: String
    private let onDismiss: () -> Void

    init(content: NSViewController, label: String, onDismiss: @escaping () -> Void) {
        self.content = content
        self.label = label
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClickToDismissCalloutController does not support NSCoder")
    }

    override func loadView() {
        let view = ClickToDismissView(onClick: onDismiss)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp("Dismisses this message")
        addChild(content)
        let contentView = content.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
        preferredContentSize = content.preferredContentSize
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === content else { return }
        preferredContentSize = content.preferredContentSize
    }
}

/// The view a click anywhere on dismisses its callout: it takes every click
/// inside it from the views it holds, including the click that would
/// otherwise only bring the callout's window forward.
@MainActor
final class ClickToDismissView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClickToDismissView does not support NSCoder")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
