import AppKit

/// Borderless `info.circle` button that reveals per-section or per-control
/// help text in an `NSPopover`.
///
/// AppKit port of the SwiftUI `InfoButton` that lived in the pre-refactor
/// `VMSettingsView.swift`. Owns its own popover so each call site is
/// independently anchored, and lazily builds the content view each time
/// the popover opens — that lets callers swap copy by guest OS without
/// re-attaching the button.
///
/// Popover content is wrapped in ``CalloutContentViewController`` so all
/// info popovers share width, padding, and font with the existing
/// missing-attachment callouts.
@MainActor
final class InfoButton: NSButton {
    private let label: String
    private let contentBuilder: () -> NSView
    private let popover = NSPopover()

    init(label: String, contentBuilder: @escaping () -> NSView) {
        self.label = label
        self.contentBuilder = contentBuilder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        image = .systemSymbol("info.circle", accessibilityDescription: "About \(label)")
        contentTintColor = .secondaryLabelColor
        isBordered = false
        bezelStyle = .smallSquare
        imagePosition = .imageOnly
        toolTip = "About \(label)"
        setAccessibilityLabel("About \(label)")
        target = self
        action = #selector(togglePopover(_:))
        popover.behavior = .transient
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InfoButton does not support NSCoder")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.close()
            return
        }
        let container = CalloutContentViewController()
        container.addArrangedContent(contentBuilder())
        popover.contentViewController = container
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

/// Build a wrapping callout-style label for use inside an `InfoButton` body.
///
/// Convenience for the common case: a single paragraph of help text at
/// callout size, leading-aligned, wrapping to the popover's body width.
@MainActor
func calloutText(_ string: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: string)
    label.font = .preferredFont(forTextStyle: .callout)
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.isSelectable = true
    label.preferredMaxLayoutWidth =
        CalloutContentViewController.defaultWidth - CalloutContentViewController.padding * 2
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
}

/// Stack multiple paragraphs vertically inside an `InfoButton` body.
@MainActor
func calloutParagraphs(_ paragraphs: [String]) -> NSStackView {
    let stack = NSStackView(views: paragraphs.map { calloutText($0) })
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    return stack
}

/// Variant of ``makeLabeledRow`` that places an info button next to the
/// leading label.
///
/// Used when the help text is specific to one control rather than the
/// whole section (e.g. `Guest Agent → "Forward guest logs"`). Mirrors the
/// old SwiftUI `toggleLabel(_:info:)` helper in `VMSettingsView.swift`.
@MainActor
func makeLabeledRowWithInfo(
    _ label: String,
    control: NSView,
    helpBuilder: @escaping () -> NSView
) -> NSStackView {
    let labelView = NSTextField(labelWithString: label)
    labelView.font = .systemFont(ofSize: NSFont.systemFontSize)

    let info = InfoButton(label: label, contentBuilder: helpBuilder)

    let labelStack = NSStackView(views: [labelView, info])
    labelStack.orientation = .horizontal
    labelStack.alignment = .centerY
    labelStack.spacing = 4
    labelStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    let row = NSStackView(views: [labelStack, settingsSpacer(), control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
}
