import Foundation
import KernovaKit
import KernovaLogging

/// The file promises of this connection's drags out, called in at the catch:
/// each drag's staging folder, its receivers, and the reads still owed.
///
/// A drag's call-in outlives its take, which ends when the drop concludes:
/// sources write their files seconds after the drop, and the host pulls each
/// one only once it has landed. The folder goes once the host is done with
/// the drag (`DragComplete`, or the connection ending) and every reader
/// callback has come back — not before, since a host still pulling reads from
/// it and a source still writing writes into it.
///
/// Each promised item is named to the host by its receiver's first file name
/// as its call-in returns, and resolved by the file of that name alone: when a
/// receiver names several, the order its reader callbacks arrive in pairs
/// nothing.
@MainActor
final class GuestDragPromises {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragPromises")

    /// The folder under the process staging root that every drag's own
    /// staging folder goes in.
    nonisolated static let stagingLabel = "agent-drag-out"

    /// One drag's called-in promises.
    private final class CallIn {
        let folder: URL
        /// Each promised item's receiver, by the item's index in the offer.
        let receivers: [Int: any FilePromiseReceiving]
        /// The name each promised item went to the host under, by the same
        /// index; empty for one that named nothing.
        var sentNames: [Int: String] = [:]
        /// The promised items the host has been told are resolved or
        /// unavailable — a folder from when its measure begins.
        var settled: Set<Int> = []
        /// The reader callbacks each receiver owes, by the same index.
        var tally: FilePromiseTally<Int>
        /// The promised folders whose tree is being measured.
        var measuring: Set<Int> = []
        /// The host is done with the drag, or the connection ended.
        var hostDone = false

        init(folder: URL, receivers: [Int: any FilePromiseReceiving]) {
            self.folder = folder
            self.receivers = receivers
            self.tally = FilePromiseTally(receivers: receivers.keys)
        }

        /// Every receiver has delivered every callback it owes and no measure
        /// is in flight.
        var readsSettled: Bool { measuring.isEmpty && tally.isQuiesced }
    }

    private let peer: any GuestDragOutPeer
    private let input: any GuestDragInput
    private let stagingRoot: ProcessStagingRoot

    /// Where every reader callback runs, one at a time, and stats what landed
    /// before anything hops to the main actor.
    private let readerQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.kernova.macosagent.drag-out-promises"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var callIns: [UInt64: CallIn] = [:]

    /// Where a drag's folder is removed, off the main actor: once it leaves
    /// ``callIns`` nothing on the main actor can reach it.
    nonisolated private let removals = DispatchQueue(
        label: "app.kernova.macosagent.drag-out-promises.removal", qos: .utility)

    /// The connection ended: reads still owed only settle, and tell nobody.
    private var stopped = false

    init(peer: any GuestDragOutPeer, input: any GuestDragInput, stagingRoot: ProcessStagingRoot) {
        self.peer = peer
        self.input = input
        self.stagingRoot = stagingRoot
    }

    // MARK: - Calling in

    /// Calls in the promises a drop of the drag `claim` names carries, read in
    /// drag order as `receivers`, and sends the host each one's name as its
    /// call-in returns.
    ///
    /// The receivers pair with the drag's promised items in order; any other
    /// count leaves which is which unknown, so then none is called in and
    /// every promised item is unavailable. Every promised item is named on
    /// every path, empty when it has no name: the host holds a Mac destination
    /// waiting for each.
    func callIn(_ claim: GuestDragWatcher.Claim, receivers: [any FilePromiseReceiving]) {
        let generation = claim.generation
        let promised = claim.items.indices.filter { claim.items[$0].fileURL == nil }
        guard !promised.isEmpty, receivers.count == promised.count else {
            Self.logger.log(
                .warning,
                "The drop carries \(receivers.count, privacy: .public) promise(s) for \(promised.count, privacy: .public) promised item(s); calling none in (gen=\(generation, privacy: .public))"
            )
            giveUp(promised, of: generation)
            return
        }
        let folder = stagingRoot.url
            .appendingPathComponent(Self.stagingLabel, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try stagingRoot.createDirectory(at: folder)
        } catch {
            Self.logger.log(
                .error,
                "Could not make a folder to call promises into (gen=\(generation, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            giveUp(promised, of: generation)
            return
        }
        let callIn = CallIn(folder: folder, receivers: Dictionary(uniqueKeysWithValues: zip(promised, receivers)))
        callIn.hostDone = stopped
        callIns[generation] = callIn
        for (index, receiver) in zip(promised, receivers) {
            let expectsFolder = claim.items[index].isDirectoryPromise
            receiver.receivePromisedFiles(
                atDestination: folder, options: [:], operationQueue: readerQueue
            ) { @Sendable [self] url, error in
                let landing = PromiseLanding(at: url, error: error, expectingFolder: expectsFolder)
                MainActorBridge.async { self.read(landing, at: url, item: index, of: generation) }
            }
            // Its reads hop to this actor, so none runs before its name is
            // recorded.
            let name = Self.name(of: receiver, item: index, generation: generation)
            callIn.sentNames[index] = name
            _ = peer.sendDragNames(generation: generation, filenames: [index: name])
        }
    }

    /// The receiver's first file name, as its call-in left it, or empty when
    /// it named nothing.
    private static func name(
        of receiver: any FilePromiseReceiving, item index: Int, generation: UInt64
    ) -> String {
        let fileNames = receiver.fileNames
        guard let first = fileNames.first else {
            logger.log(
                .warning,
                "Promised item \(index, privacy: .public) named no file when called in (gen=\(generation, privacy: .public))"
            )
            return ""
        }
        if fileNames.count > 1 {
            logger.log(
                .warning,
                "Promised item \(index, privacy: .public) names \(fileNames.count, privacy: .public) files; only the first goes to the host (gen=\(generation, privacy: .public))"
            )
        }
        return first
    }

    /// Answers a call-in that called nothing in: `promised` will never be
    /// written, and the host is told none of them will be named.
    private func giveUp(_ promised: [Int], of generation: UInt64) {
        if !promised.isEmpty {
            _ = peer.markPromisedDragItemsUnavailable(generation: generation, repIndices: promised)
        }
        _ = peer.sendDragNames(
            generation: generation, filenames: Dictionary(uniqueKeysWithValues: promised.map { ($0, "") }))
    }

    // MARK: - Reads

    /// One reader callback of item `index`: the file named to the host
    /// resolves it; any other stays in the folder until the folder goes.
    ///
    /// The item is unavailable when its receiver names at most one file and
    /// the callback failed, or once the receiver has delivered every callback
    /// it owes without the named file — a failure from a receiver naming
    /// several cannot be paired with a file, since AppKit says to ignore its
    /// URL. Once the host is done with the drag, a callback is only counted.
    private func read(_ landing: PromiseLanding, at url: URL, item index: Int, of generation: UInt64) {
        guard let callIn = callIns[generation] else { return }
        let fileCount = callIn.receivers[index]?.fileNames.count ?? 0
        callIn.tally.record(from: index, naming: fileCount)
        defer { releaseIfDone(generation) }
        guard !callIn.hostDone, !callIn.settled.contains(index) else { return }
        let name = callIn.sentNames[index] ?? ""
        switch landing {
        case .failed(let reason) where fileCount <= 1:
            Self.logger.log(
                .warning,
                "Promised item \(index, privacy: .public) was not written (gen=\(generation, privacy: .public)): \(reason, privacy: .public)"
            )
            return markUnavailable(index, of: callIn, generation: generation)
        case .file(let byteCount) where !name.isEmpty && url.lastPathComponent == name:
            callIn.settled.insert(index)
            _ = peer.resolvePromisedDragItem(
                generation: generation, repIndex: index, fileURL: url, byteCount: byteCount)
            return
        case .folder where !name.isEmpty && url.lastPathComponent == name:
            callIn.settled.insert(index)
            callIn.measuring.insert(index)
            input.measureFolders([index: url]) { [self] sizes in
                measured(sizes[index], at: url, item: index, of: generation)
            }
            return
        case .failed(let reason):
            Self.logger.log(
                .notice,
                "A file of promised item \(index, privacy: .public) was not written (gen=\(generation, privacy: .public)): \(reason, privacy: .public)"
            )
        case .file, .folder:
            Self.logger.log(
                .notice,
                "Promised item \(index, privacy: .public) wrote a file other than the one it was named by, which stays in the guest (gen=\(generation, privacy: .public))"
            )
        }
        guard callIn.tally.hasDeliveredAll(from: index) else { return }
        Self.logger.log(
            .warning,
            "Promised item \(index, privacy: .public) delivered every file without the one it was named by (gen=\(generation, privacy: .public))"
        )
        markUnavailable(index, of: callIn, generation: generation)
    }

    private func markUnavailable(_ index: Int, of callIn: CallIn, generation: UInt64) {
        callIn.settled.insert(index)
        _ = peer.markPromisedDragItemsUnavailable(generation: generation, repIndices: [index])
    }

    /// A promised folder's tree came back measured.
    private func measured(_ byteCount: Int?, at url: URL, item index: Int, of generation: UInt64) {
        guard let callIn = callIns[generation] else { return }
        callIn.measuring.remove(index)
        defer { releaseIfDone(generation) }
        guard !callIn.hostDone else { return }
        _ = peer.resolvePromisedDragItem(
            generation: generation, repIndex: index, fileURL: url, byteCount: byteCount ?? 0)
    }

    // MARK: - Letting go

    /// The host is done with the drag under `generation`.
    func complete(generation: UInt64) {
        callIns[generation]?.hostDone = true
        releaseIfDone(generation)
    }

    /// The connection ended: every drag's folder goes once its reads settle.
    func stop() {
        stopped = true
        for (generation, callIn) in callIns {
            callIn.hostDone = true
            releaseIfDone(generation)
        }
    }

    /// Removes the drag's folder once the host is done and every read is in.
    private func releaseIfDone(_ generation: UInt64) {
        guard let callIn = callIns[generation], callIn.hostDone, callIn.readsSettled else { return }
        callIns[generation] = nil
        let folder = callIn.folder
        removals.async {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Self.logger.log(
                    .warning,
                    "Could not remove the promises' folder (gen=\(generation, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    #if DEBUG
    /// Test seam: returns once every folder removal queued so far is done.
    func waitForFolderRemovalsForTesting() {
        removals.sync {}
    }
    #endif
}

/// What one reader callback landed, read on the reader queue.
private enum PromiseLanding: Sendable {
    /// A regular file of `byteCount` bytes.
    case file(byteCount: Int)
    /// A folder, whose tree is still to be measured.
    case folder
    /// Nothing the promise declared; `reason` is log detail.
    case failed(String)

    /// Stats what a promise landed at `url`, which must be the kind its type
    /// declared: a host pulls a promise as the kind its offer named.
    init(at url: URL, error: (any Error)?, expectingFolder: Bool) {
        if let error {
            self = .failed(error.localizedDescription)
            return
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        if expectingFolder {
            self = values?.isDirectory == true ? .folder : .failed("The promise of a folder wrote no folder")
            return
        }
        guard values?.isRegularFile == true, let byteCount = values?.fileSize else {
            self = .failed("The promise of a file wrote no file")
            return
        }
        self = .file(byteCount: byteCount)
    }
}
