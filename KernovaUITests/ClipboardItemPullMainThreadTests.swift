import AppKit
import Foundation
import KernovaSynchronization
import Testing

@testable import KernovaKit

/// A peer's item pulled by a paste fired on the main thread: the publisher's
/// hold runs the application's event loop instead of parking. It needs a live
/// `NSApplication`, which only this app-hosted bundle has.
@Suite("Item pulls on the main thread", .caseScoped)
@MainActor
struct ClipboardItemPullMainThreadTests {
    /// Completes each pull from a block performed on the main run loop, which
    /// only a turning loop runs.
    private final class RunLoopPuller: ClipboardItemPulling {
        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            RunLoop.main.perform { completion(Data("live".utf8)) }
        }

        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            RunLoop.main.perform { completion(nil) }
        }
    }

    @Test("a main-thread paste keeps the run loop turning: a block performed on it completes the pull")
    func performedMainRunLoopBlockCompletesPull() throws {
        let waits = Locked<[NestedEventLoopWait]>([])
        let items = ClipboardOfferSource(content: ClipboardContent(text: "offered")).items
        let specs = ClipboardPasteboardPublisher.itemSpecs(
            for: items, concealed: false, puller: RunLoopPuller(),
            eventLoopWait: {
                let wait = NestedEventLoopWait.current()
                if let wait { waits.withLock { $0.append(wait) } }
                return wait
            })

        // A parked main thread could never run the completion.
        let served = try #require(specs.first).provide(ClipboardContent.utf8TextUTI)

        #expect(served == Data("live".utf8))
        let waitsTaken = waits.withLock { $0 }
        try #require(waitsTaken.count == 1)
        #expect(waitsTaken[0].endingsForTesting == [.resolved])
    }
}
