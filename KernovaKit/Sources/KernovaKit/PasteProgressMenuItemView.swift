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
    /// Wide enough for a headline naming a VM plus the byte-progress line with
    /// its file counter, without making the whole dropdown unusually wide.
    private static let contentWidth: CGFloat = 312
    /// Leading inset aligning the readout with the dropdown's ordinary item
    /// titles, whose text starts clear of the checkmark gutter.
    private static let leadingInset: CGFloat = 21
    private static let trailingInset: CGFloat = 12
    private static let verticalInset: CGFloat = 6
    private static let rowSpacing: CGFloat = 4

    private let headline = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    /// The fraction the bar should show, committed to it only while the view is
    /// on screen — see `viewDidMoveToWindow`.
    private var pendingFraction: Double = 0
    private let byteProgress = NSTextField(labelWithString: "")
    private let itemCounter = NSTextField(labelWithString: "")
    private let timeRemaining = NSTextField(labelWithString: "")

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

        for label in [byteProgress, itemCounter, timeRemaining] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
        }
        // The counter is the fixed-width anchor of its row; the byte line gives
        // way to it when space runs out.
        itemCounter.alignment = .right
        itemCounter.lineBreakMode = .byClipping
        itemCounter.setContentCompressionResistancePriority(.required, for: .horizontal)
        itemCounter.setContentHuggingPriority(.required, for: .horizontal)
        byteProgress.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let byteRow = NSStackView(views: [byteProgress, itemCounter])
        byteRow.orientation = .horizontal
        byteRow.alignment = .firstBaseline
        byteRow.distribution = .fill
        byteRow.spacing = 8

        let stack = NSStackView(views: [headline, bar, byteRow, timeRemaining])
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
            byteRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Pin the content width so the rows lay out (and the height measures)
            // against the width the menu will actually give this view.
            stack.widthAnchor.constraint(
                equalToConstant: Self.contentWidth - Self.leadingInset - Self.trailingInset),
        ])
        return stack
    }

    /// Commits the bar's stored fraction when the view lands on screen.
    ///
    /// This is the *only* place a detached bar's value catches up, and it is
    /// what keeps the dropdown's first frame honest: `apply` runs on every
    /// throttled snapshot from the reveal onward — before the dropdown ever
    /// opens — and committing those to an `NSProgressIndicator` that has no
    /// window left its first on-screen frame animating out of the accumulated,
    /// never-displayed state (observed live on #650 as the bar opening around
    /// 40 % and springing back). Withholding commits until the view is attached
    /// means the control's first on-screen animation runs from its built value
    /// of zero up to the real fraction — an ordinary fill.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            bar.doubleValue = pendingFraction
        } else {
            // Detached: park the control back at zero so its next appearance
            // fills from empty again, rather than springing down from whatever
            // the previous showing left behind (the view is kept across
            // pastes).
            bar.doubleValue = 0
        }
    }

    /// Applies a snapshot in place, so the readout keeps advancing while its
    /// menu is open.
    public func apply(_ snapshot: PasteMaterializationSnapshot) {
        headline.stringValue = PasteProgressFormat.headline(sourceName: snapshot.sourceName)
        pendingFraction = snapshot.fractionComplete
        // Off screen, the value is only recorded — see `viewDidMoveToWindow`.
        if window != nil { bar.doubleValue = pendingFraction }
        byteProgress.stringValue = PasteProgressFormat.byteProgress(
            bytesTransferred: snapshot.bytesTransferred,
            totalBytes: snapshot.totalBytes,
            bytesPerSecond: snapshot.bytesPerSecond)
        itemCounter.stringValue =
            PasteProgressFormat.itemCounter(
                completed: snapshot.filesCompleted, total: snapshot.fileCount) ?? ""
        timeRemaining.stringValue =
            PasteProgressFormat.timeRemaining(seconds: snapshot.secondsRemaining) ?? ""
        setAccessibilityLabel(PasteProgressFormat.summary(snapshot))
    }
}
