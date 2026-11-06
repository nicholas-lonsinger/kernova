import Foundation
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import Testing

/// The live guest's file work for a drag out — the drop folder's watch, the
/// coordinated read of each arrival, the dropped files' sizes — run against
/// real folders on the real queues, where Dispatch and the file coordinator
/// call back.
@Suite("SystemGuestDragInput", .caseScoped)
@MainActor
struct GuestDragSystemTests {
    private let scratch = TestScratchDirectory(prefix: "GuestDragSystemTests")

    /// What the live input handed back on the main actor.
    @MainActor
    private final class Heard {
        var appeared: [String] = []
        var arrivals: [GuestDragArrival] = []
        var refused = 0
    }

    @Test(
        "the live watch hands back each entry as it appears, each coordinated read is granted, and cancelling lets go of the folder"
    )
    func theLiveWatchRunsToItsCancel() async throws {
        let folder = scratch.url.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: folder.appendingPathComponent("IMG_00001.jpg"))
        let closed = Locked(0)
        let gate = AsyncGate()
        let input = SystemGuestDragInput(watchClosed: {
            closed.withLock { $0 += 1 }
            gate.notify()
        })
        let heard = Heard()

        let cancel = input.watchEntries(in: folder) { urls in
            heard.appeared += urls.map(\.lastPathComponent)
            for url in urls {
                input.coordinateRead(of: url) { arrival in
                    if let arrival { heard.arrivals.append(arrival) } else { heard.refused += 1 }
                    gate.notify()
                }
            }
            gate.notify()
        }
        // An entry already there when the watch began counts.
        try await gate.wait { heard.arrivals.count == 1 }
        let album = folder.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: false)
        try await gate.wait { heard.arrivals.count == 2 }

        cancel()

        try await gate.wait { closed.withLock { $0 } == 1 }
        #expect(heard.appeared == ["IMG_00001.jpg", "Album"])
        #expect(heard.arrivals.map(\.url.lastPathComponent) == ["IMG_00001.jpg", "Album"])
        #expect(heard.arrivals.map(\.isFolder) == [false, true])
        #expect(heard.refused == 0)
    }

    @Test("the live sizing opens each file, sizes a folder by its tree, and sizes nothing it cannot read")
    func theLiveSizing() async throws {
        let directory = scratch.url.appendingPathComponent("dragged", isDirectory: true)
        let tree = directory.appendingPathComponent("Tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("note.txt")
        try Data("four".utf8).write(to: file)
        try Data("alpha".utf8).write(to: tree.appendingPathComponent("a.txt"))
        let input = SystemGuestDragInput(measureFolder: { _ in 42 })

        let sizes = await withCheckedContinuation { continuation in
            input.sizeFiles([file, tree, directory.appendingPathComponent("gone.txt")]) {
                continuation.resume(returning: $0)
            }
        }

        #expect(sizes == [4, 42, nil])
    }
}
