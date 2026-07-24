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
    private let bar = PasteProgressBarView()
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
            bar.heightAnchor.constraint(equalToConstant: PasteProgressBarView.barHeight),
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
        bar.fraction = snapshot.fractionComplete
        itemName.stringValue = snapshot.currentItemName ?? ""
        itemCounter.stringValue =
            PasteProgressFormat.itemCounter(
                completed: snapshot.filesCompleted, total: snapshot.fileCount) ?? ""
        detail.stringValue =
            PasteProgressFormat.detail(
                bytesPerSecond: snapshot.bytesPerSecond,
                secondsRemaining: snapshot.secondsRemaining) ?? ""
        percent.stringValue = PasteProgressFormat.percent(fraction: snapshot.fractionComplete)
        setAccessibilityLabel(PasteProgressFormat.summary(snapshot))
    }
}

/// The readout's determinate fill bar, drawn by hand.
///
/// Deliberately not an `NSProgressIndicator`: that control animates every value
/// commit with a private fluid spring — including its first commit after
/// landing in a window, observed live (#643) as the bar opening at an arbitrary
/// fill and springing back to the real fraction when the dropdown first
/// appeared — and it exposes no non-animated setter to suppress that with. The
/// readout redraws at the shared throttle's ~1 %/100 ms cadence anyway, so the
/// per-chunk motion *is* the animation; drawing the stored fraction directly
/// makes the first frame correct by construction.
@MainActor
final class PasteProgressBarView: NSView {
    /// The bar's fixed height (the capsule diameter).
    static let barHeight: CGFloat = 5

    /// Fill fraction, clamped to `0...1` at draw time.
    var fraction: Double = 0 {
        didSet {
            if fraction != oldValue { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let clamped = min(1, max(0, fraction))
        guard clamped > 0 else { return }
        // Never narrower than the capsule's own diameter, so a tiny fraction
        // draws a dot rather than a squashed sliver.
        let width = max(bounds.width * clamped, bounds.height)
        let fill = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
