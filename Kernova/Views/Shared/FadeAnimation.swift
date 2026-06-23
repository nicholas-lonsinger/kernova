import AppKit

/// The app's canonical duration for alpha cross-dissolves — overlay show/hide,
/// subtitle fade-in, scroll-hint reveal.
///
/// One value so a tweak to the standard fade lands everywhere at once. A site
/// may pass a different `duration` to ``animateFade(_:to:duration:completion:)``
/// when its element genuinely warrants it.
let standardFadeDuration: TimeInterval = 0.2

/// Cross-dissolves one or more views' `alphaValue` to `target` with the app's
/// standard ease-in-ease-out timing.
///
/// Replaces the hand-rolled `NSAnimationContext.runAnimationGroup` +
/// `CAMediaTimingFunction(name: .easeInEaseOut)` dance that otherwise gets
/// repeated at every fade site. All views animate together in a single
/// transaction. `completion`, if given, runs on the main thread when the
/// animation finishes — e.g. to hide a fully-faded-out overlay.
@MainActor
func animateFade(
    _ views: NSView...,
    to target: CGFloat,
    duration: TimeInterval = standardFadeDuration,
    completion: (@MainActor () -> Void)? = nil
) {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if let completion {
            // RATIONALE: NSAnimationContext completion handlers are not actor-isolated
            // by the framework but always run on the main thread, so bridge back via
            // assumeIsolated. Set on the context (a non-`@Sendable` property) rather
            // than passed as the `@Sendable` `completionHandler:` argument, which would
            // warn on capturing the non-Sendable `@MainActor` closure.
            context.completionHandler = { MainActor.assumeIsolated { completion() } }
        }
        for view in views {
            view.animator().alphaValue = target
        }
    }
}
