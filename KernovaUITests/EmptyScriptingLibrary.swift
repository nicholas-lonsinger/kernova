import AppKit
import Testing

@testable import KernovaUI

/// The application element the scripting dictionary resolves `virtual machines`
/// and `networks` through, answering with an empty library. The shipping app's
/// `AppDelegate` answers them from its library; KernovaTestHost installs no
/// delegate, and a specifier evaluated against the application then reaches
/// `NSApplication`'s own KVC, whose `NSUnknownKeyException` crashes the host.
@MainActor
final class EmptyScriptingLibraryDelegate: NSObject, NSApplicationDelegate {
    /// Retained here because `NSApplication.delegate` is weak.
    private static let shared = EmptyScriptingLibraryDelegate()

    /// Makes this the application's delegate; once is enough for the process.
    static func install() {
        if NSApplication.shared.delegate !== shared {
            NSApplication.shared.delegate = shared
        }
    }

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        AppDelegate.scriptingKeys.contains(key)
    }

    @objc var virtualMachines: [VMScriptObject] { [] }

    @objc var networks: [VMNetworkScriptObject] { [] }
}

/// Installs ``EmptyScriptingLibraryDelegate`` before the suite's tests run.
struct EmptyScriptingLibraryTrait: SuiteTrait, TestTrait {
    var isRecursive: Bool { true }

    func prepare(for test: Test) async throws {
        await EmptyScriptingLibraryDelegate.install()
    }
}

extension Trait where Self == EmptyScriptingLibraryTrait {
    /// Resolves the application's scripting elements to an empty library.
    static var emptyScriptingLibrary: Self { Self() }
}
