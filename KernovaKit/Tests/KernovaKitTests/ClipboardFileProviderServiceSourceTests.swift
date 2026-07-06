import FileProvider
import Foundation
import Testing
import os

@testable import KernovaKit

/// Unit tests for `ClipboardFileProviderServiceSource` cancellation — the handle
/// returned by `fetchStagedFile` that wires Finder's cancel button (via the
/// `fetchContents` `Progress`) to an in-progress pull.
///
/// These exercise the *pending* pull path, which needs no live owner connection:
/// with nothing accepted, `fetchStagedFile` enqueues the pull and returns, so the
/// cancel handle drives the completion deterministically without standing up an
/// anonymous-XPC round trip. Cancellation fires its completion synchronously, so
/// the assertions don't need to wait.
@Suite("ClipboardFileProviderServiceSource cancellation")
struct ClipboardFileProviderServiceSourceTests {
    /// A config with no code-signing pins and a test app group / service name, so a
    /// source can be constructed without touching production identifiers.
    ///
    /// The source stands up an anonymous listener in `init` (harmless in a test
    /// process) but never accepts a connection here, keeping every pull pending.
    private static let testConfig = ClipboardFileProviderConfig(
        appGroupIdentifier: "8MT4P4GZL2.app.kernova.test",
        serviceName: NSFileProviderServiceName("app.kernova.clipboard.test.relay"),
        reconnectNotificationName: "app.kernova.clipboard.test.reconnect",
        domainIdentifier: "kernova-clipboard-test",
        domainDisplayName: "Kernova Clipboard (Test)",
        containerDirectoryName: "FileProviderTest",
        loggerSubsystem: "app.kernova.test",
        extensionLoggerSubsystem: "app.kernova.test.fileprovider",
        ownerCodeSigningRequirement: nil,
        extensionCodeSigningRequirement: nil)

    private func makeSource() -> ClipboardFileProviderServiceSource {
        ClipboardFileProviderServiceSource(
            config: Self.testConfig,
            logger: Logger(subsystem: "app.kernova.test", category: "ServiceSourceTest"))
    }

    @Test("cancelling a pending pull completes it once with NSUserCancelledError")
    func cancelPendingPullCompletesWithUserCancelled() {
        let source = makeSource()
        let result = Box<Result<String, NSError>?>(nil)

        // No accepted connection → the pull enqueues and waits; the completion has
        // not run yet.
        let cancellation = source.fetchStagedFile(generation: 5, repIndex: 2) { outcome in
            result.value = outcome
        }
        #expect(result.value == nil)

        cancellation.cancel()

        guard case .failure(let error)? = result.value else {
            Issue.record("expected a failure result after cancel, got \(String(describing: result.value))")
            return
        }
        #expect(error.domain == NSCocoaErrorDomain)
        #expect(error.code == NSUserCancelledError)
    }

    @Test("cancel is idempotent — the completion fires exactly once across repeated cancels")
    func cancelIsIdempotent() {
        let source = makeSource()
        let callCount = Box(0)

        let cancellation = source.fetchStagedFile(generation: 1, repIndex: 0) { _ in
            callCount.value += 1
        }
        cancellation.cancel()
        cancellation.cancel()
        cancellation.cancel()

        #expect(callCount.value == 1)
    }
}
