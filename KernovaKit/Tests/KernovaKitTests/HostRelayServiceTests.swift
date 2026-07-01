import FileProvider
import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `HostRelayService` — the object the resident agent exports on
/// `…xpc`, multiplexing the extension's `fetchFile` (forwarded to the
/// registered clipboard relay, or `serverUnreachable` when none) and the
/// launcher's `showUserInterface`/`openVMs` (each forwarded to its own injected
/// closure).
@Suite("HostRelayService")
struct HostRelayServiceTests {
    /// A `@Sendable`-safe mutable cell so the synchronous XPC-style reply/closure
    /// can record what it observed.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Records the `(generation, repIndex)` it was asked for and replies with a
    /// fixed staged path, so forwarding can be asserted.
    private final class MockRelay: NSObject, ClipboardFileProviderRelay, @unchecked Sendable {
        private let lock = NSLock()
        private var lastCallStorage: (UInt64, Int)?
        var lastCall: (UInt64, Int)? { lock.withLock { lastCallStorage } }
        let stagedPath: String?

        init(stagedPath: String?) {
            self.stagedPath = stagedPath
            super.init()
        }

        func fetchFile(
            generation: UInt64, repIndex: Int,
            reply: @escaping @Sendable (String?, NSError?) -> Void
        ) {
            lock.withLock { lastCallStorage = (generation, repIndex) }
            reply(stagedPath, nil)
        }
    }

    @Test("fetchFile with no registered provider replies serverUnreachable")
    func noProviderServerUnreachable() {
        let service = HostRelayService(
            loggerSubsystem: "app.kernova.test", onShowUserInterface: {}, onOpenVMs: { _ in })
        let path = Box<String?>(nil)
        let error = Box<NSError?>(nil)
        let replied = Box(false)

        service.fetchFile(generation: 1, repIndex: 0) { stagedPath, nsError in
            path.value = stagedPath
            error.value = nsError
            replied.value = true
        }

        #expect(replied.value)
        #expect(path.value == nil)
        #expect(error.value?.domain == NSFileProviderErrorDomain)
        #expect(error.value?.code == NSFileProviderError.serverUnreachable.rawValue)
    }

    @Test("fetchFile forwards (generation, repIndex) to the registered provider")
    func forwardsToProvider() {
        let provider = MockRelay(stagedPath: "/staged/file")
        let service = HostRelayService(
            loggerSubsystem: "app.kernova.test", onShowUserInterface: {}, onOpenVMs: { _ in })
        service.setRelayProvider(provider)
        let path = Box<String?>(nil)

        service.fetchFile(generation: 7, repIndex: 3) { stagedPath, _ in path.value = stagedPath }

        #expect(provider.lastCall?.0 == 7)
        #expect(provider.lastCall?.1 == 3)
        #expect(path.value == "/staged/file")
    }

    @Test("Clearing the provider returns to serverUnreachable")
    func clearingProviderResetsToUnreachable() {
        let service = HostRelayService(
            loggerSubsystem: "app.kernova.test", onShowUserInterface: {}, onOpenVMs: { _ in })
        service.setRelayProvider(MockRelay(stagedPath: "/staged/file"))
        service.setRelayProvider(nil)
        let error = Box<NSError?>(nil)

        service.fetchFile(generation: 1, repIndex: 0) { _, nsError in error.value = nsError }

        #expect(error.value?.code == NSFileProviderError.serverUnreachable.rawValue)
    }

    @Test("showUserInterface invokes the injected closure and replies")
    func showUserInterfaceInvokesClosureAndReplies() {
        let summoned = Box(false)
        let service = HostRelayService(
            loggerSubsystem: "app.kernova.test",
            onShowUserInterface: { summoned.value = true },
            onOpenVMs: { _ in })
        let replied = Box(false)

        service.showUserInterface { replied.value = true }

        #expect(summoned.value)
        #expect(replied.value)
    }

    @Test("openVMs forwards the paths to the injected closure and replies")
    func openVMsForwardsPathsAndReplies() {
        let received = Box<[String]>([])
        let service = HostRelayService(
            loggerSubsystem: "app.kernova.test",
            onShowUserInterface: {},
            onOpenVMs: { received.value = $0 })
        let replied = Box(false)

        service.openVMs(paths: ["/a.kernova", "/b.kernova"]) { replied.value = true }

        #expect(received.value == ["/a.kernova", "/b.kernova"])
        #expect(replied.value)
    }

    @Test("HostRelayListener startServing/stopServing toggle the fetchFile backing")
    func listenerStartStopTogglesFetchBacking() {
        // start() is intentionally NOT called — the transport's start/stop of the
        // fetchFile backing is exercised without standing up a live Mach service.
        let listener = HostRelayListener(
            machServiceName: "app.kernova.test.xpc",
            inboundCodeSigningRequirement: "anchor apple",
            loggerSubsystem: "app.kernova.test",
            onShowUserInterface: {},
            onOpenVMs: { _ in })
        let service = listener.relayServiceForTesting

        // Before serving: no provider → serverUnreachable.
        let before = Box<NSError?>(nil)
        service.fetchFile(generation: 1, repIndex: 0) { _, e in before.value = e }
        #expect(before.value?.code == NSFileProviderError.serverUnreachable.rawValue)

        // Enable: forwards to the registered relay.
        listener.startServing(MockRelay(stagedPath: "/staged/file"))
        let served = Box<String?>(nil)
        service.fetchFile(generation: 2, repIndex: 1) { p, _ in served.value = p }
        #expect(served.value == "/staged/file")

        // Disable: backing cleared → back to serverUnreachable.
        listener.stopServing()
        let after = Box<NSError?>(nil)
        service.fetchFile(generation: 3, repIndex: 2) { _, e in after.value = e }
        #expect(after.value?.code == NSFileProviderError.serverUnreachable.rawValue)
    }
}
