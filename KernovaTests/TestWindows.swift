import AppKit
import Testing

// MARK: - Scope

/// Opens a ``TestWindowScope`` around each test case and closes it when the
/// case ends, however it ends, so no window the case made or adopted outlives
/// it.
struct ScopedWindowsTrait: TestTrait, SuiteTrait, TestScoping {
    typealias TestScopeProvider = Self

    /// The scope of the test case running on this task.
    @TaskLocal static var scope: TestWindowScope?

    /// Recursive so a suite's annotation reaches the cases inside it, which is
    /// the level a scope belongs to.
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let scope = TestWindowScope()
        do {
            try await Self.$scope.withValue(scope) { try await function() }
        } catch {
            await scope.close()
            throw error
        }
        await scope.close()
    }
}

extension Trait where Self == ScopedWindowsTrait {
    /// Closes every window a test case in this suite makes or adopts when the
    /// case ends; a suite that makes a window carries it.
    static var scopedWindows: Self { Self() }
}

/// The windows one test case holds, taken off screen together by ``close()``.
@MainActor
final class TestWindowScope {
    private var windows: [NSWindow] = []

    nonisolated init() {}

    fileprivate func track(_ window: NSWindow) {
        windows.append(window)
    }

    /// Takes every window off screen, newest first: its sheets ended, a window
    /// that is itself a sheet ended on its parent, then the window closed.
    ///
    /// A sheet ends as `.cancel`, which answers none of an alert's buttons. A
    /// closed window keeps its attached sheet, which is why sheets end first.
    func close() {
        while let window = windows.popLast() {
            Self.endSheets(on: window)
            window.sheetParent?.endSheet(window, returnCode: .cancel)
            window.close()
        }
    }

    /// Ends every sheet on `window`, each one's own sheets first.
    ///
    /// Ending the attached sheet attaches the next one queued behind it, so
    /// this runs until none is left.
    private static func endSheets(on window: NSWindow) {
        while let sheet = window.attachedSheet {
            endSheets(on: sheet)
            window.endSheet(sheet, returnCode: .cancel)
        }
    }
}

/// Puts `window` in the running test case's scope.
@MainActor
private func enroll(_ window: NSWindow) {
    // The default `true` double-releases an ARC-owned window on `close()`,
    // which the scope calls on every window it holds.
    window.isReleasedWhenClosed = false
    guard let scope = ScopedWindowsTrait.scope else {
        Issue.record("A test window outlives its test unless its suite carries `.scopedWindows`")
        return
    }
    scope.track(window)
}

// MARK: - Factories

/// A window that stays beyond every display however AppKit moves it: the
/// initializer clamps a titled window's content rect onto one, ordering in runs
/// `constrainFrameRect(_:to:)`, and a sheet slides its parent into view through
/// `setFrameOrigin(_:)`. It animates nothing, since AppKit draws a close
/// animation as a window of its own.
private final class ParkedTestWindow: NSWindow {
    /// Right of the bounding box of every display, where no screen reaches.
    private static var parkedOrigin: NSPoint {
        let displays = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        guard !displays.isNull else { return .zero }
        return NSPoint(x: displays.maxX + 1_000, y: displays.minY)
    }

    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        setFrameOrigin(Self.parkedOrigin)
        animationBehavior = .none
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        NSRect(origin: Self.parkedOrigin, size: frameRect.size)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(Self.parkedOrigin)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(NSRect(origin: Self.parkedOrigin, size: frameRect.size), display: flag)
    }
}

/// Builds a window beyond every display — `isVisible` once ordered in, able to
/// take key and carry a sheet, and never in front of the person at the Mac —
/// that the test case's scope closes; the one way a test makes a window.
@MainActor
func makeTestWindow(
    styleMask: NSWindow.StyleMask, contentSize: NSSize = NSSize(width: 200, height: 100)
) -> NSWindow {
    let window = ParkedTestWindow(
        contentRect: NSRect(origin: .zero, size: contentSize),
        styleMask: styleMask,
        backing: .buffered,
        defer: false
    )
    enroll(window)
    return window
}

/// ``makeTestWindow(styleMask:contentSize:)``, ordered in.
///
/// A sheet begun on a window that isn't goes up on the display by itself.
@MainActor
@discardableResult
func showTestWindow(
    styleMask: NSWindow.StyleMask, contentSize: NSSize = NSSize(width: 200, height: 100)
) -> NSWindow {
    let window = makeTestWindow(styleMask: styleMask, contentSize: contentSize)
    window.orderFront(nil)
    return window
}

/// Hosts `view` as the content view of a window ordered in — beyond every
/// display, as ``makeTestWindow(styleMask:contentSize:)`` places it — for
/// behavior that only runs against one.
///
/// `ScrollMoreIndicator` holds its scroller flash until there is a visible
/// window to animate the fade-in against, so a flash assertion made against a
/// window never ordered in asserts the opposite of what the app does.
///
/// `view` becomes the content view rather than a bare subview: a pane root with
/// `translatesAutoresizingMaskIntoConstraints` off and no pinning constraints
/// hands its frame to the layout engine, which resolves it to something the test
/// never asked for. `size` defaults to the frame `view` already carries; pass a
/// measured `preferredContentSize` for a pane that sizes its own window.
@MainActor
@discardableResult
func showInTestWindow(_ view: NSView, size: NSSize? = nil) -> NSWindow {
    let window = makeTestWindow(styleMask: [.titled, .closable])
    window.setContentSize(size ?? view.frame.size)
    window.contentView = view
    window.orderFront(nil)
    return window
}

/// Takes a window the app itself made into the test case's scope, which closes
/// it: invisible and click-through, still `isVisible` to AppKit.
///
/// Moving it beyond the displays instead leaves part of it on one: AppKit
/// keeps a visible titled window's edge on screen. The window server first
/// draws a window when the main-actor turn that ordered it in ends, so call
/// this in that turn, with no suspension after the show.
@MainActor
func adoptAppWindow(_ window: NSWindow) {
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    enroll(window)
}
