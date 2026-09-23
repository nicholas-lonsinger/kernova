import AppKit

/// The app's canonical duration for alpha cross-dissolves — overlay show/hide,
/// subtitle fade-in, scroll-hint reveal.
let standardFadeDuration: TimeInterval = 0.2

/// Cross-dissolves one or more views' `alphaValue` to `target` with the app's
/// standard ease-in-ease-out timing.
///
/// All views animate together in a single transaction. `completion`, if given,
/// runs on the main thread when the animation finishes.
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
            // NSAnimationContext runs completion handlers on the main thread without
            // declaring actor isolation, hence `assumeIsolated`. The context's
            // `completionHandler` property is non-`@Sendable`; the `@Sendable`
            // `completionHandler:` argument would warn on capturing the
            // non-Sendable `@MainActor` closure.
            context.completionHandler = { MainActor.assumeIsolated { completion() } }
        }
        for view in views {
            view.animator().alphaValue = target
        }
    }
}
