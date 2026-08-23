import AppKit

/// The live transfer readout inside a status-item dropdown, for a transfer
/// running in the background.
///
/// Every label must stay single-line and truncate rather than wrap: a menu item
/// that changed height while its menu was open would re-lay-out the dropdown
/// under the user's cursor. The Cancel button is the view's only control; the
/// menu item carrying it is disabled, and a custom view's own subviews track
/// mouse events regardless of that.
@MainActor
public final class ClipboardProgressMenuItemView: NSView {
    /// Content width — fits a headline naming a VM plus the byte-progress line
    /// and its file counter.
    private static let contentWidth: CGFloat = 312
    /// Leading inset aligning the readout with the dropdown's ordinary item
    /// titles, whose text starts clear of the checkmark gutter.
    private static let leadingInset: CGFloat = 21
    private static let trailingInset: CGFloat = 12
    private static let verticalInset: CGFloat = 6
    private static let rowSpacing: CGFloat = 4

    private let headline = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let bar = NSProgressIndicator()
    /// The fraction the bar should show, committed to it only while the view is
    /// on screen — see `viewDidMoveToWindow`.
    private var pendingFraction: Double = 0
    private let byteProgress = NSTextField(labelWithString: "")
    private let itemCounter = NSTextField(labelWithString: "")
    private let timeRemaining = NSTextField(labelWithString: "")
    private let pendingNote = NSTextField(labelWithString: "")

    /// Stops the transfer the readout is showing.
    ///
    /// `nil` hides the Cancel button, for a readout of something that cannot be
    /// stopped. Set it before the view is shown; it is read at click time, so a
    /// later change takes effect without a rebuild.
    public var onCancel: (() -> Void)? {
        didSet { cancelButton.isHidden = onCancel == nil }
    }

    /// Creates the readout, sized to its content.
    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 1))
        let stack = buildLayout()
        // NSMenu sizes a custom item from its view's frame, so settle the height
        // once here. Measure the stack, not `self`, whose fitting size depends on
        // how the menu later treats this view's autoresizing.
        frame.size = NSSize(
            width: Self.contentWidth,
            height: stack.fittingSize.height + Self.verticalInset * 2)
        // Measured with the button in place, then hidden: `NSStackView` drops a
        // hidden view from layout, so measuring without it would size the item
        // too short for the first readout that *can* be cancelled — and an
        // `NSMenu` takes a custom item's height from the frame, once.
        cancelButton.isHidden = true
        pendingNote.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipboardProgressMenuItemView does not support NSCoder")
    }

    /// Builds the row hierarchy and returns the outer stack, so the caller can
    /// measure it.
    private func buildLayout() -> NSStackView {
        headline.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        headline.textColor = .labelColor
        headline.lineBreakMode = .byTruncatingTail
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.controlSize = .small

        for label in [byteProgress, itemCounter, timeRemaining, pendingNote] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
        }
        // Shares the time row's line rather than taking one of its own: the menu
        // takes this view's height once, so a row that comes and goes has to cost
        // nothing vertically.
        pendingNote.alignment = .right
        pendingNote.lineBreakMode = .byClipping
        pendingNote.setContentCompressionResistancePriority(.required, for: .horizontal)
        pendingNote.setContentHuggingPriority(.required, for: .horizontal)
        timeRemaining.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

        let headlineRow = NSStackView(views: [headline, cancelButton])
        headlineRow.orientation = .horizontal
        headlineRow.alignment = .centerY
        headlineRow.distribution = .fill
        headlineRow.spacing = 8

        let timeRow = NSStackView(views: [timeRemaining, pendingNote])
        timeRow.orientation = .horizontal
        timeRow.alignment = .firstBaseline
        timeRow.distribution = .fill
        timeRow.spacing = 8

        let stack = NSStackView(views: [headlineRow, bar, byteRow, timeRow])
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
            headlineRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            byteRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            timeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
    /// The only place a detached bar's value catches up: `apply` runs on every
    /// throttled snapshot from the reveal onward, and committing those to an
    /// `NSProgressIndicator` with no window leaves its first on-screen frame
    /// animating out of never-displayed state (observed as the bar opening around
    /// 40 % and springing back). Withholding commits until the view is attached
    /// keeps that first animation an ordinary fill from zero.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            bar.doubleValue = pendingFraction
        } else {
            // The view is kept across transfers: park the control at zero so its
            // next appearance fills from empty again.
            bar.doubleValue = 0
        }
    }

    /// Applies a snapshot in place, so the readout keeps advancing while its
    /// menu is open.
    public func apply(_ snapshot: ClipboardProgressSnapshot) {
        headline.stringValue = ClipboardProgressFormat.headline(
            direction: snapshot.direction, peerName: snapshot.peerName,
            gesture: snapshot.gesture)
        pendingFraction = snapshot.fractionComplete
        // Off screen, the value is only recorded — see `viewDidMoveToWindow`.
        if window != nil { bar.doubleValue = pendingFraction }
        byteProgress.stringValue = ClipboardProgressFormat.byteProgress(
            bytesTransferred: snapshot.bytesTransferred,
            totalBytes: snapshot.totalBytes,
            bytesPerSecond: snapshot.bytesPerSecond)
        itemCounter.stringValue =
            ClipboardProgressFormat.itemCounter(
                completed: snapshot.filesCompleted, total: snapshot.fileCount) ?? ""
        timeRemaining.stringValue =
            ClipboardProgressFormat.timeRemaining(seconds: snapshot.secondsRemaining) ?? ""
        let pending = ClipboardProgressFormat.pendingNote(count: snapshot.pendingBehind)
        pendingNote.stringValue = pending ?? ""
        pendingNote.isHidden = pending == nil
        setAccessibilityLabel(ClipboardProgressFormat.summary(snapshot))
    }

    /// Runs the cancel handler for whatever the readout is currently showing.
    ///
    /// Read at click time rather than captured, so a handler replaced between two
    /// operations cancels the live one.
    @objc private func cancelTapped() {
        onCancel?()
    }

    #if DEBUG
    /// Test seam: the Cancel button, so a test can assert its visibility and
    /// drive its action without a live menu.
    public var cancelButtonForTesting: NSButton { cancelButton }
    #endif
}
