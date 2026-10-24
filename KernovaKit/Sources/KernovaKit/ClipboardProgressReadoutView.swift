import AppKit

/// The live readout of a transfer running in the background, laid out for the
/// status item's dropdown or its callout.
///
/// Every label must stay single-line and truncate rather than wrap: the readout
/// takes its height once, at init, and must not change it while either surface
/// shows it — a menu item that changed height while its menu was open would
/// re-lay-out the dropdown under the user's cursor. The Cancel button is the
/// view's only control; the menu item carrying it is disabled, and a custom
/// view's own subviews track mouse events regardless of that.
@MainActor
public final class ClipboardProgressReadoutView: NSView {
    /// The surface the readout sits in, which sets its width and insets.
    public enum Surface: Sendable {
        /// An item in the status item's dropdown, aligned with the menu's
        /// ordinary item titles.
        case dropdownItem
        /// The status item's callout, padded and sized as every callout is.
        case callout
    }

    /// A surface's width and the insets from its edges to the readout's rows.
    private struct Metrics {
        let width: CGFloat
        let leading: CGFloat
        let trailing: CGFloat
        let vertical: CGFloat

        init(_ surface: Surface) {
            switch surface {
            case .dropdownItem:
                // Fits a headline naming a VM plus the byte-progress line and its
                // file counter; the leading inset starts the rows where the
                // menu's item titles start, clear of the checkmark gutter.
                width = 312
                leading = 21
                trailing = 12
                vertical = 6
            case .callout:
                width = CalloutStyle.width
                leading = CalloutStyle.padding
                trailing = CalloutStyle.padding
                vertical = CalloutStyle.padding
            }
        }
    }

    private static let rowSpacing: CGFloat = 4

    private let metrics: Metrics
    private let headline = NSTextField(labelWithString: "")
    private let cancelButton = FirstClickButton(title: "Cancel", target: nil, action: nil)
    private let bar = NSProgressIndicator()
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

    /// Creates the readout for `surface`, sized to its content.
    ///
    /// The frame is the readout's whole size: a dropdown item takes it from the
    /// frame, and a callout's content size is pinned to it.
    public init(surface: Surface) {
        metrics = Metrics(surface)
        super.init(frame: NSRect(x: 0, y: 0, width: metrics.width, height: 1))
        let stack = buildLayout()
        // Settle the height once here. Measure the stack, not `self`, whose
        // fitting size depends on how the surface later treats this view's
        // autoresizing.
        frame.size = NSSize(
            width: metrics.width,
            height: stack.fittingSize.height + metrics.vertical * 2)
        // Measured with the button in place, then hidden: `NSStackView` drops a
        // hidden view from layout, so measuring without it would size the
        // readout too short for the first one that *can* be cancelled.
        cancelButton.isHidden = true
        pendingNote.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipboardProgressReadoutView does not support NSCoder")
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
        // Shares the time row's line rather than taking one of its own: the
        // readout's height is settled once, so a row that comes and goes has to
        // cost nothing vertically.
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
            stack.topAnchor.constraint(equalTo: topAnchor, constant: metrics.vertical),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -metrics.vertical),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.leading),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.trailing),
            headlineRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            byteRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            timeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Pin the content width so the rows lay out (and the height measures)
            // against the width the surface will actually give this view.
            stack.widthAnchor.constraint(
                equalToConstant: metrics.width - metrics.leading - metrics.trailing),
        ])
        return stack
    }

    /// Applies a snapshot in place, so the readout keeps advancing while its
    /// surface is on screen.
    public func apply(_ snapshot: ClipboardProgressSnapshot) {
        headline.stringValue = ClipboardProgressFormat.headline(
            direction: snapshot.direction, peerName: snapshot.peerName,
            gesture: snapshot.gesture)
        if bar.isIndeterminate != snapshot.awaitsSize {
            bar.isIndeterminate = snapshot.awaitsSize
            if snapshot.awaitsSize { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
        }
        bar.doubleValue = snapshot.fractionComplete
        byteProgress.stringValue = ClipboardProgressFormat.byteProgress(
            bytesTransferred: snapshot.bytesTransferred,
            totalBytes: snapshot.totalBytes,
            bytesPerSecond: snapshot.bytesPerSecond,
            awaitsSize: snapshot.awaitsSize)
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
    /// drive its action without a live surface.
    public var cancelButtonForTesting: NSButton { cancelButton }

    /// Test seam: the fraction the bar shows.
    public var barFractionForTesting: Double { bar.doubleValue }

    /// Test seam: whether the bar shows no fraction at all.
    public var barIsIndeterminateForTesting: Bool { bar.isIndeterminate }

    /// Test seam: the byte line.
    public var byteProgressForTesting: String { byteProgress.stringValue }
    #endif

    /// The Cancel button, taking the click that also activates its app.
    ///
    /// The callout is up while its app is often not active — the guest agent
    /// never is, and the host isn't after a drop onto Finder — and a Cancel that
    /// only activated the app would let the transfer run on.
    private final class FirstClickButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
