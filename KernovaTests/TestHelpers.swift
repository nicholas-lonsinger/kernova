import AppKit
import Foundation
import Observation
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import Kernova

// Bundle-specific test helpers for KernovaTests. The event-driven/poll wait
// primitives (`AsyncGate`, `waitUntil`, `TestFailure`), the ephemeral-
// `UserDefaults` helpers (`makeEphemeralDefaults`, `withEphemeralDefaults`),
// and the blocking-bridge GCD hop (`offCooperativePool`) live in the shared
// `KernovaTestSupport` package product — see its doc comments.
//
// `waitForChange` below is KernovaTests-only: it observes `@MainActor`
// `@Observable` production state
// directly via `withObservationTracking`, which only this bundle's tests need
// — the GuestAgent/KernovaKit bundles' predicates read `Sendable` boxes
// (`AtomicInt`, `PolicyBox`) with no such observable type to track.

// MARK: - Ephemeral UserDefaults

/// Wraps `makeEphemeralDefaults` (`KernovaTestSupport`) in an `AppPreferences`, for suites that only
/// need the typed wrapper (e.g. to construct a `VMLibraryViewModel`) and never
/// inspect the raw `UserDefaults` store directly.
func makeEphemeralPreferences(suiteName: String) -> AppPreferences {
    AppPreferences(defaults: makeEphemeralDefaults(suiteName: suiteName))
}

// MARK: - VZ error fixtures

/// The plain-start shape of the running-VM cap: VZ reports the code at the top
/// level.
func makeVMLimitExceededError() -> NSError {
    NSError(
        domain: VZError.errorDomain,
        code: VZError.Code.virtualMachineLimitExceeded.rawValue)
}

/// The install shape of the same cap: `VZMacOSInstaller.install()` reports it as
/// `.installationFailed` with the real code underneath, so only a chain walk
/// classifies it.
func makeInstallVMLimitExceededError() -> NSError {
    makeVZErrorChain(depth: 1, around: makeVMLimitExceededError())
}

/// `error` wrapped in `depth` nested `.installationFailed` errors.
func makeVZErrorChain(depth: Int, around error: NSError) -> NSError {
    var wrapped = error
    for _ in 0..<depth {
        wrapped = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.installationFailed.rawValue,
            userInfo: [NSUnderlyingErrorKey: wrapped])
    }
    return wrapped
}

// MARK: - drainMainQueue

/// Waits for everything already queued on the main queue — one FIFO turn of
/// the `MainActorBridge.async` bridge a listener's accepted channel rides.
func drainMainQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        MainActorBridge.async { continuation.resume() }
    }
}

// MARK: - expectEOF

/// Asserts `channel` reaches EOF — the peer closed its end — rather than
/// producing another frame.
///
/// Event-driven via `nextFrame`, whose stuck-stream backstop bounds the wait:
/// EOF resolves it immediately, a frame or a timeout records a test failure.
/// Used by the #145 channel-admission tests to observe a service dropping a
/// non-conformant peer.
@MainActor
func expectEOF(on channel: VsockChannel) async {
    do {
        let frame = try await nextFrame(from: channel)
        Issue.record("Expected channel EOF, got frame \(String(describing: frame.payload))")
    } catch let failure as TestFailure {
        #expect(failure.message.contains("EOF"), "Expected EOF, got: \(failure.message)")
    } catch {
        Issue.record("Expected channel EOF, got error \(error)")
    }
}

// MARK: - waitForChange

/// Event-driven replacement for `waitUntil` when the predicate reads
/// `@Observable` state on a production object directly — i.e. there is no test
/// double in the loop to call `AsyncGate.notify()`.
///
/// `withObservationTracking` suspends the waiter until a property the predicate
/// actually reads changes, then the loop re-checks — so the wait resolves on the
/// mutation itself, not on a 50 ms poll tick. Like `AsyncGate`, an idle waiter
/// adds **zero** wake-ups to the shared (and, on CI, contended) MainActor, and
/// `timeout` is a stuck-condition backstop the happy path never reaches rather
/// than the success deadline. This is the fix for the poll-budget flakes in the
/// flaky-CI investigation; see docs/TESTING.md "Async waits in tests".
///
/// The predicate must read every value it inspects through an `@Observable`
/// getter so tracking registers a dependency, and it must be **side-effect-free**
/// — it is evaluated several times per wait (the arming pass, the immediate-hit
/// re-check, and each outer-loop iteration). Computed properties that read
/// observed stored properties qualify (e.g. `agentStatus` reads `isUnresponsive`),
/// but tracking only registers the properties actually read on the arming pass:
/// a getter that short-circuits *before* reaching the property that will change
/// won't wake the waiter, which then resolves only via the deadline backstop. A
/// predicate over plain non-observed state would never be re-evaluated and must
/// keep `waitUntil`.
@MainActor
func waitForChange(
    timeout: Duration = .seconds(testWaitBackstop),
    until predicate: @escaping @MainActor () -> Bool
) async throws {
    let stopwatch = BackstopStopwatch()
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
        if ContinuousClock.now >= deadline {
            throw TestFailure.backstop(
                "Observed condition not met within \(timeout)",
                stopwatch: stopwatch, timeout: timeout)
        }
        await armObservationOnce(deadline: deadline, predicate: predicate)
    }
}

/// Suspends until the next change to any `@Observable` property read by
/// `predicate`, an immediate hit (the predicate already holds at arm time,
/// closing the arm-vs-change race), or the `deadline` backstop — whichever
/// comes first.
///
/// Mirrors `AsyncGate.armOnce`, but the wake source is observation tracking
/// instead of an explicit `notify()`.
@MainActor
private func armObservationOnce(
    deadline: ContinuousClock.Instant,
    predicate: @escaping @MainActor () -> Bool
) async {
    // Captured so it can be cancelled once the wait resolves via observation (or
    // the immediate-hit re-check); otherwise every happy-path arm would leak a
    // Task sleeping until `deadline`, the opposite of the "zero wake-ups" goal.
    var backstop: Task<Void, Never>?
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let once = ResumeOnce()
        // Arm tracking over whatever observable state the predicate reads. The
        // `onChange` fires once, during the willSet of the first such property
        // to change; the awaiting task then resumes and the outer loop
        // re-checks (by which point the setter has completed).
        withObservationTracking {
            _ = predicate()
        } onChange: {
            once.fire { cont.resume() }
        }
        // Close the arm-vs-change race: a change may have landed between the
        // outer while-check and arming. If the predicate already holds, resume
        // now so the loop re-checks instead of waiting for a change that may
        // never come.
        if predicate() {
            once.fire { cont.resume() }
            return
        }
        // Backstop: resume at the deadline so a genuinely stuck condition fails
        // the wait instead of hanging.
        backstop = Task { @MainActor in
            try? await Task.sleep(until: deadline, clock: ContinuousClock())
            once.fire { cont.resume() }
        }
    }
    // Resolved (observation, immediate hit, or the backstop itself) — cancel the
    // backstop so it doesn't linger asleep until `deadline`.
    backstop?.cancel()
}

// MARK: - View-tree search

/// The first `T` that `matches` in the subtree rooted at `view`, depth-first.
@MainActor
func firstSubview<T: NSView>(
    _ type: T.Type, in view: NSView, where matches: (T) -> Bool = { _ in true }
) -> T? {
    if let candidate = view as? T, matches(candidate) { return candidate }
    for subview in view.subviews {
        if let match = firstSubview(type, in: subview, where: matches) { return match }
    }
    return nil
}

/// Every `T` that `matches` in the subtree rooted at `view`, depth-first.
@MainActor
func allSubviews<T: NSView>(
    _ type: T.Type, in view: NSView, where matches: (T) -> Bool = { _ in true }
) -> [T] {
    var found: [T] = []
    if let candidate = view as? T, matches(candidate) { found.append(candidate) }
    for subview in view.subviews {
        found.append(contentsOf: allSubviews(type, in: subview, where: matches))
    }
    return found
}

/// The first push button titled `title` in the subtree rooted at `view`.
///
/// Skips pop-up buttons, whose `title` is whichever item is selected.
@MainActor
func findButton(titled title: String, in view: NSView) -> NSButton? {
    firstSubview(NSButton.self, in: view) { !($0 is NSPopUpButton) && $0.title == title }
}

/// The first label reading exactly `text` in the subtree rooted at `view`.
@MainActor
func findLabel(withText text: String, in view: NSView) -> NSTextField? {
    firstSubview(NSTextField.self, in: view) { $0.stringValue == text }
}

/// The first label whose text contains `text` in the subtree rooted at `view`.
@MainActor
func findLabel(containing text: String, in view: NSView) -> NSTextField? {
    firstSubview(NSTextField.self, in: view) { $0.stringValue.contains(text) }
}

/// The first editable text field in the subtree rooted at `view`.
@MainActor
func findEditableField(in view: NSView) -> NSTextField? {
    firstSubview(NSTextField.self, in: view) { $0.isEditable }
}

/// Every text field in the subtree rooted at `view`, in depth-first order.
@MainActor
func collectLabels(in view: NSView) -> [NSTextField] {
    allSubviews(NSTextField.self, in: view)
}

/// Whether `view` and every ancestor up to `root` is unhidden — what it takes
/// for `view` to actually be on screen within `root`.
@MainActor
func isVisible(_ view: NSView, within root: NSView) -> Bool {
    var node: NSView? = view
    while let current = node {
        if current.isHidden { return false }
        if current === root { return true }
        node = current.superview
    }
    return true
}

// MARK: - AppKit window factory

/// Builds a plain window with `isReleasedWhenClosed` disarmed.
///
/// The default `true` double-releases an ARC-owned `NSWindow` on `close()`
/// (see `SettingsWindowController`'s own `isReleasedWhenClosed = false` for the
/// same reason) — fatal under ARC.
@MainActor
func makeTestWindow(styleMask: NSWindow.StyleMask) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: styleMask,
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    return window
}

/// Hosts `view` as an on-screen window's content view, for behavior that only
/// runs against one.
///
/// `ScrollMoreIndicator` holds its scroller flash until there is a visible
/// window to animate the fade-in against, so a flash assertion made off screen
/// asserts the opposite of what the app does.
///
/// `view` becomes the content view rather than a bare subview: a pane root with
/// `translatesAutoresizingMaskIntoConstraints` off and no pinning constraints
/// hands its frame to the layout engine, which resolves it to something the test
/// never asked for. `size` defaults to the frame `view` already carries; pass a
/// measured `preferredContentSize` for a pane that sizes its own window.
///
/// Keep the returned window alive for the length of the test.
@MainActor
func showInTestWindow(_ view: NSView, size: NSSize? = nil) -> NSWindow {
    let window = makeTestWindow(styleMask: [.titled, .closable])
    window.setContentSize(size ?? view.frame.size)
    window.contentView = view
    window.orderFront(nil)
    return window
}
