import AppKit
import Foundation
import KernovaSynchronization
import KernovaWire
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
        func whenEnded(_ handler: @escaping @Sendable () -> Void) {}
        func canServe(item: Int, representation: Int) -> Bool { false }

        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            RunLoop.main.perform { completion(Data("live".utf8)) }
        }

        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            RunLoop.main.perform { completion(nil) }
        }
    }

    /// Completes each pull as ``RunLoopPuller`` does, first noting whether a
    /// wait held the main thread as it ran.
    private final class HoldRecordingPuller: ClipboardItemPulling {
        let heldDuringPull = Locked<[Bool]>([])

        func whenEnded(_ handler: @escaping @Sendable () -> Void) {}
        func canServe(item: Int, representation: Int) -> Bool { false }

        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            RunLoop.main.perform { [heldDuringPull] in
                let held = MainActor.assumeIsolated { NestedEventLoopWait.holdsMainThread }
                heldDuringPull.withLock { $0.append(held) }
                completion(Data("live".utf8))
            }
        }

        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            RunLoop.main.perform { completion(nil) }
        }
    }

    @Test("a main-thread paste's wait holds the main thread while it runs and not after, announcing each change")
    func waitHoldsTheMainThreadWhileItRuns() throws {
        var text = Representation()
        text.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        text.storage = .inline
        var item = OfferedItem()
        item.representations = [text]
        let puller = HoldRecordingPuller()
        let specs = ClipboardPasteboardPublisher.itemSpecs(
            for: [item], concealed: false, puller: puller, eventLoopWait: { NestedEventLoopWait.current() })
        let announced = Locked<[Bool]>([])
        let observer = NotificationCenter.default.addObserver(
            forName: NestedEventLoopWait.holdChangedNotification, object: nil, queue: nil
        ) { _ in
            let held = MainActor.assumeIsolated { NestedEventLoopWait.holdsMainThread }
            announced.withLock { $0.append(held) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(!NestedEventLoopWait.holdsMainThread)

        let served = try #require(specs.first).provide(ClipboardContent.utf8TextUTI)

        #expect(served == Data("live".utf8))
        #expect(puller.heldDuringPull.withLock { $0 } == [true])
        #expect(!NestedEventLoopWait.holdsMainThread)
        #expect(announced.withLock { $0 } == [true, false])
    }

    @Test("a main-thread paste keeps the run loop turning: a block performed on it completes the pull")
    func performedMainRunLoopBlockCompletesPull() throws {
        let waits = Locked<[NestedEventLoopWait]>([])
        var text = Representation()
        text.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        text.storage = .inline
        var item = OfferedItem()
        item.representations = [text]
        let items = [item]
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
