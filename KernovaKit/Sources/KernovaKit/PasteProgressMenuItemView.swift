import AppKit

/// The live transfer readout inside a status-item dropdown, for a paste
/// materializing in the background (#643).
///
/// Hosted as an `NSMenuItem.view` by both the host app's and the guest agent's
/// status-item controllers, so a paste reads identically in whichever direction
/// it is running. Non-actionable: it reports, and the menu item that carries it
/// is disabled.
///
/// Built to keep a fixed size across every update — single-line labels that
/// truncate rather than wrap — because a menu item that changed height while its
/// menu was open would re-lay-out the dropdown under the user's cursor.
@MainActor
public final class PasteProgressMenuItemView: NSView {
    /// Content width.
    ///
    /// Wide enough for a headline naming a VM plus a speed-and-time line,
    /// without making the whole dropdown unusually wide.
    private static let contentWidth: CGFloat = 260
    /// Leading inset aligning the readout with the dropdown's ordinary item
    /// titles, whose text starts clear of the checkmark gutter.
    private static let leadingInset: CGFloat = 21
    private static let trailingInset: CGFloat = 12
    private static let verticalInset: CGFloat = 6
    private static let rowSpacing: CGFloat = 4

    private let headline = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let itemName = NSTextField(labelWithString: "")
    private let itemCounter = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")

    /// Creates the readout, sized to its content.
    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 1))
        let stack = buildLayout()
        // NSMenu sizes a custom item from its view's frame, so settle on the
        // measured height once here; nothing in `apply` can change it, since
        // every label is single-line. Measured from the stack rather than from
        // `self`, whose own fitting size depends on how the menu later treats
        // this view's autoresizing.
        frame.size = NSSize(
            width: Self.contentWidth,
            height: stack.fittingSize.height + Self.verticalInset * 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PasteProgressMenuItemView does not support NSCoder")
    }

    /// Builds the row hierarchy and returns the outer stack, so the caller can
    /// measure it.
    private func buildLayout() -> NSStackView {
        headline.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        headline.textColor = .labelColor
        headline.lineBreakMode = .byTruncatingTail

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.controlSize = .small

        for label in [itemName, itemCounter, detail, percent] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
        }
        // The counter and percent are the fixed-width anchors of their rows;
        // the name and detail give way to them when space runs out.
        for trailing in [itemCounter, percent] {
            trailing.alignment = .right
            trailing.lineBreakMode = .byClipping
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.setContentHuggingPriority(.required, for: .horizontal)
        }
        for leading in [itemName, detail] {
            leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let itemRow = NSStackView(views: [itemName, itemCounter])
        let detailRow = NSStackView(views: [detail, percent])
        for row in [itemRow, detailRow] {
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.distribution = .fill
            row.spacing = 8
        }

        let stack = NSStackView(views: [headline, bar, itemRow, detailRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            itemRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Pin the content width so the rows lay out (and the height measures)
            // against the width the menu will actually give this view.
            stack.widthAnchor.constraint(
                equalToConstant: Self.contentWidth - Self.leadingInset - Self.trailingInset),
        ])
        return stack
    }

    /// Applies a snapshot in place, so the readout keeps advancing while its
    /// menu is open.
    public func apply(_ snapshot: PasteMaterializationSnapshot) {
        headline.stringValue = PasteProgressFormat.headline(sourceName: snapshot.sourceName)
        bar.doubleValue = snapshot.fractionComplete
        itemName.stringValue = snapshot.currentItemName ?? ""
        itemCounter.stringValue =
            PasteProgressFormat.itemCounter(
                completed: snapshot.itemsCompleted, total: snapshot.itemCount) ?? ""
        detail.stringValue =
            PasteProgressFormat.detail(
                bytesPerSecond: snapshot.bytesPerSecond,
                secondsRemaining: snapshot.secondsRemaining) ?? ""
        percent.stringValue = PasteProgressFormat.percent(fraction: snapshot.fractionComplete)
        setAccessibilityLabel(PasteProgressFormat.summary(snapshot))
    }
}
