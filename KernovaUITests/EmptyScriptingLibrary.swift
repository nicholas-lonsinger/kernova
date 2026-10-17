import AppKit

@testable import KernovaUI

/// The bundle's `NSPrincipalClass`, which XCTest instantiates once when it
/// loads the bundle, before any test runs: it makes
/// ``EmptyScriptingLibraryDelegate`` the application's delegate for the whole
/// process.
final class TestBundlePrincipal: NSObject {
    override init() {
        super.init()
        MainActor.assumeIsolated { EmptyScriptingLibraryDelegate.install() }
    }
}

/// The application element the scripting dictionary resolves `virtual machines`
/// and `networks` through, answering with an empty library. The shipping app's
/// `AppDelegate` answers them from its library; KernovaTestHost installs no
/// delegate, and a specifier evaluated against the application then reaches
/// `NSApplication`'s own KVC, whose `NSUnknownKeyException` crashes the host.
@MainActor
final class EmptyScriptingLibraryDelegate: NSObject, NSApplicationDelegate {
    /// Retained here because `NSApplication.delegate` is weak.
    private static let shared = EmptyScriptingLibraryDelegate()

    fileprivate static func install() {
        NSApplication.shared.delegate = shared
    }

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        AppDelegate.scriptingKeys.contains(key)
    }

    @objc var virtualMachines: [VMScriptObject] { [] }

    @objc var networks: [VMNetworkScriptObject] { [] }
}
