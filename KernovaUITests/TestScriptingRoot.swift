import AppKit

@testable import KernovaUI

/// The bundle's `NSPrincipalClass`, which XCTest instantiates once when it
/// loads the bundle, before any test runs: it makes the application a
/// ``VMScriptingApplication``, as the app's own is, and ``TestScriptingRoot``
/// its delegate for the whole process.
final class TestBundlePrincipal: NSObject {
    override init() {
        super.init()
        MainActor.assumeIsolated { TestScriptingRoot.install() }
    }
}

/// The scripting root a test's Apple events resolve through: the app's own
/// element surface, answered by the gateway ``serving(_:_:)`` hands it, and
/// by none — an empty library, and no verb — anywhere else.
///
/// KernovaTestHost installs no delegate, and a specifier evaluated against the
/// application then reaches `NSApplication`'s own KVC, whose
/// `NSUnknownKeyException` crashes the host. The gateway is the task's own, and
/// every task that task starts inherits it, so tests running side by side
/// each reach theirs through the one process-wide delegate.
@MainActor
final class TestScriptingRoot: VMScriptingRoot {
    /// Retained here because `NSApplication.delegate` is weak.
    private static let shared = TestScriptingRoot()

    fileprivate static func install() {
        // KernovaTestHost starts a plain NSApplication, before this bundle,
        // which holds every Kernova class, is loaded.
        let host: AnyClass = object_getClass(NSApplication.shared) ?? NSApplication.self
        precondition(
            class_getInstanceSize(VMScriptingApplication.self) == class_getInstanceSize(host),
            "VMScriptingApplication added a stored property, so the test host's application can't become one")
        object_setClass(NSApplication.shared, VMScriptingApplication.self)
        NSApplication.shared.delegate = shared
    }

    @TaskLocal private static var gateway: VMScriptingGateway?

    override var scriptingGateway: VMScriptingGateway? { Self.gateway }

    /// Runs `body` with `gateway` answering every Apple event it dispatches,
    /// and every one the gateway dispatches again on behalf of a command it
    /// suspends there — the task that answers it inherits the gateway.
    static func serving<Result>(
        _ gateway: VMScriptingGateway, _ body: () throws -> Result
    ) rethrows -> Result {
        try $gateway.withValue(gateway, operation: body)
    }
}
