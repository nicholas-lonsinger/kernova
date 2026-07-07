import FileProvider
import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `FileProviderRelayService` — the relay the owner
/// exports over the `NSFileProviderServicing` connection (#460).
///
/// The extension calls `fetchFile` back on it at `fetchContents`; this exercises
/// the reply contract (staged path on success, mapped `NSFileProviderError` on
/// failure) without standing up a live anonymous-XPC connection.
@Suite("FileProviderRelayService")
struct FileProviderRelayServiceTests {
    /// Records the `(generation, repIndex)` it was asked for and returns a fixed
    /// result, so forwarding and result mapping can be asserted.
    private final class MockPullProvider: FileProviderPullProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var lastCallStorage: (UInt64, Int)?
        var lastCall: (UInt64, Int)? { lock.withLock { lastCallStorage } }
        let result: Result<String, FileProviderPullError>

        init(result: Result<String, FileProviderPullError>) {
            self.result = result
        }

        func fetchStagedFile(
            generation: UInt64, repIndex: Int
        ) -> Result<String, FileProviderPullError> {
            lock.withLock { lastCallStorage = (generation, repIndex) }
            return result
        }
    }

    @Test("fetchFile forwards (generation, repIndex) and replies with the staged path on success")
    func successRepliesWithStagedPath() {
        let provider = MockPullProvider(result: .success("/staged/file"))
        let service = FileProviderRelayService(
            pullProvider: provider, loggerSubsystem: "app.kernova.test")
        let path = Box<String?>(nil)
        let error = Box<NSError?>(nil)

        service.fetchFile(generation: 7, repIndex: 3) { stagedPath, nsError in
            path.value = stagedPath
            error.value = nsError
        }

        #expect(provider.lastCall?.0 == 7)
        #expect(provider.lastCall?.1 == 3)
        #expect(path.value == "/staged/file")
        #expect(error.value == nil)
    }

    @Test("a noCurrentOffer pull failure maps to NSFileProviderError.noSuchItem")
    func noCurrentOfferMapsToNoSuchItem() {
        let service = FileProviderRelayService(
            pullProvider: MockPullProvider(result: .failure(.noCurrentOffer)),
            loggerSubsystem: "app.kernova.test")
        let path = Box<String?>("unset")
        let error = Box<NSError?>(nil)

        service.fetchFile(generation: 1, repIndex: 0) { stagedPath, nsError in
            path.value = stagedPath
            error.value = nsError
        }

        #expect(path.value == nil)
        #expect(error.value?.domain == NSFileProviderErrorDomain)
        #expect(error.value?.code == NSFileProviderError.noSuchItem.rawValue)
    }

    @Test("a pullFailed failure maps to NSFileProviderError.serverUnreachable")
    func pullFailedMapsToServerUnreachable() {
        let service = FileProviderRelayService(
            pullProvider: MockPullProvider(result: .failure(.pullFailed)),
            loggerSubsystem: "app.kernova.test")
        let error = Box<NSError?>(nil)

        service.fetchFile(generation: 1, repIndex: 0) { _, nsError in error.value = nsError }

        #expect(error.value?.domain == NSFileProviderErrorDomain)
        #expect(error.value?.code == NSFileProviderError.serverUnreachable.rawValue)
    }
}
