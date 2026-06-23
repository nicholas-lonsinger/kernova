import AppKit
import os

/// Watches one wizard step's scroll view and reports whether its content has been
/// scrolled to the bottom — the "scroll to continue" gate behind issue #374.
///
/// A plain `@MainActor` helper (matching the wizard's "factory + helper, no step
/// base class" style) created by each *scrolling* step view controller, which
/// forwards `onChange` to `VMCreationViewModel.setCurrentStepScrollGateSatisfied`.
/// It is deliberately **not** baked into the shared `makeGroupedFormScrollView`:
/// the settings pane consumes that factory too and must never gate.
///
/// "Satisfied" means the gate imposes no restriction — either the content fits
/// (no overflow) or it overflows and the user has reached the bottom. The state
/// is derived purely from live scroll geometry (clip-view bounds + document-view
/// frame), recomputed whenever either changes, so a step that grows its content
/// in place (the IPSW/boot steps rebuild a conditional section) re-gates without
/// remounting.
@MainActor
final class WizardScrollGate {
    private static let logger = Logger(subsystem: "app.kernova", category: "WizardScrollGate")

    /// Fractional-point tolerance so rounding in the layout engine doesn't leave
    /// the gate stuck one sub-pixel short of "at the bottom".
    private static let epsilon: CGFloat = 1.0

    private weak var scrollView: NSScrollView?
    private let onChange: (Bool) -> Void

    /// Last value handed to `onChange`, so we only report transitions. Seeded to
    /// `true` to match `VMCreationViewModel`'s satisfied default — a step that
    /// never overflows then produces no redundant write.
    private var lastReported = true

    /// Once the bottom is reached the gate latches satisfied for this step visit.
    ///
    /// Having seen the whole step, the user can then scroll back up to revisit a
    /// field without the gate (and the Next button) flapping. A fresh step mount
    /// makes a fresh gate, so re-entering a step re-gates.
    private var latchedSatisfied = false

    /// - Parameters:
    ///   - scrollView: the step's scroll view (its `documentView` holds the content).
    ///   - onChange: invoked on the main actor whenever the satisfied state flips.
    init(scrollView: NSScrollView, onChange: @escaping (Bool) -> Void) {
        self.scrollView = scrollView
        self.onChange = onChange

        let clip = scrollView.contentView
        // Scrolling and clip resizes both post bounds-changed; content growth posts
        // the document's frame-changed. Together they cover every geometry change.
        clip.postsBoundsChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(geometryChanged),
            name: NSView.boundsDidChangeNotification, object: clip)
        if let documentView = scrollView.documentView {
            center.addObserver(
                self, selector: #selector(geometryChanged),
                name: NSView.frameDidChangeNotification, object: documentView)
        }

        // Establish a baseline. Pre-layout this measures zero-size geometry → no
        // overflow → satisfied, matching the default; the first real layout pass
        // fires the notifications and re-evaluates.
        recompute()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func geometryChanged() {
        recompute()
    }

    private func recompute() {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        // The clip view's bounds carry both the scroll offset (origin) and the
        // visible height (size). With the flipped clip view, origin.y grows from 0
        // at the top to `docHeight - visibleHeight` at the bottom. Reading the clip
        // bounds directly avoids `documentVisibleRect`, whose `visibleRect`
        // computation returns the whole document for a view that isn't in a live
        // window (which would make "at bottom" always true off-screen).
        let clipBounds = scrollView.contentView.bounds
        let docHeight = documentView.frame.height
        let overflows = docHeight > clipBounds.height + Self.epsilon
        let atBottom = clipBounds.maxY >= docHeight - Self.epsilon
        report(satisfied: !overflows || atBottom)
    }

    private func report(satisfied: Bool) {
        // Sticky once satisfied: ignore any later "engaged" so scrolling back up
        // (or content settling) can't re-disable Next after the user reached the end.
        guard !latchedSatisfied else { return }
        guard satisfied != lastReported else { return }
        lastReported = satisfied
        if satisfied { latchedSatisfied = true }
        Self.logger.debug("Scroll gate \(satisfied ? "satisfied" : "engaged", privacy: .public)")
        onChange(satisfied)
    }
}
