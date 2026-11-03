import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaLogging
import KernovaWire

/// The file promises of drags the host takes out of the guest, called in at
/// the catcher's delivering drop: each drag's staging folder, its receivers,
/// and the reads still owed.
///
/// A call-in outlives its take: sources write their files seconds after the
/// call-in, and a pull of a promise waits until its file has landed. The
/// folder goes once the drag's offer has ended and every reader callback has
/// come back — not before, since a host still pulling reads from it and a
/// source still writing writes into it.
///
/// Each promised item is named by its receiver's first file name as its
/// call-in returns, and lands as the file of that name alone: when a receiver
/// names several, the order its reader callbacks arrive in pairs nothing.
@MainActor
final class GuestDragPromises {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragPromises")

    /// The folder under the process staging root that every drag's own
    /// staging folder goes in.
    nonisolated static let stagingLabel = "agent-drag-out"

    /// One drag's called-in promises.
    @MainActor
    final class CallIn {
        let folder: URL
        /// Each promised item's receiver, by the item's index in the drag.
        let receivers: [Int: any FilePromiseReceiving]
        /// Each promised item's name and landing, by the same index.
        private(set) var offered: [Int: (name: String, landing: GuestDragLanding)] = [:]
        /// The reader callbacks each receiver owes, by the same index.
        var tally: FilePromiseTally<Int>
        /// The drag's offer ended.
        var offerDone = false

        init(folder: URL, receivers: [Int: any FilePromiseReceiving]) {
            self.folder = folder
            self.receivers = receivers
            self.tally = FilePromiseTally(receivers: receivers.keys)
        }

        fileprivate func name(_ index: Int, _ name: String) {
            offered[index] = (name, GuestDragLanding())
        }
    }

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

    /// Every call-in whose folder is still held.
    private var callIns: [ObjectIdentifier: CallIn] = [:]

    /// Where a drag's folder is removed, off the main actor: once it leaves
    /// ``callIns`` nothing on the main actor can reach it.
    nonisolated private let removals = DispatchQueue(
        label: "app.kernova.macosagent.drag-out-promises.removal", qos: .utility)

    init(stagingRoot: ProcessStagingRoot) {
        self.stagingRoot = stagingRoot
    }

    // MARK: - Calling in

    /// Calls in the promises among `items`, read off the drop in drag order as
    /// `receivers`, into a staging folder of their own; nil unless every one
    /// named a file as its call-in returned.
    ///
    /// The receivers pair with the drag's promised items in order; any other
    /// count leaves which is which unknown, so then none is called in.
    func callIn(_ items: [GuestDragItem], receivers: [any FilePromiseReceiving]) -> CallIn? {
        let promised = items.indices.filter { items[$0].fileURL == nil }
        guard !promised.isEmpty, receivers.count == promised.count else {
            Self.logger.log(
                .warning,
                "The drag carries \(receivers.count, privacy: .public) promise(s) for \(promised.count, privacy: .public) promised item(s); calling none in"
            )
            return nil
        }
        let folder = stagingRoot.url
            .appendingPathComponent(Self.stagingLabel, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try stagingRoot.createDirectory(at: folder)
        } catch {
            Self.logger.log(
                .error, "Could not make a folder to call promises into: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        let callIn = CallIn(folder: folder, receivers: Dictionary(uniqueKeysWithValues: zip(promised, receivers)))
        callIns[ObjectIdentifier(callIn)] = callIn
        var named = true
        for (index, receiver) in zip(promised, receivers) {
            let expectsFolder = items[index].isDirectoryPromise
            receiver.receivePromisedFiles(
                atDestination: folder, options: [:], operationQueue: readerQueue
            ) { @Sendable [self] url, error in
                let landing = PromiseLanding(at: url, error: error, expectingFolder: expectsFolder)
                MainActorBridge.async { self.read(landing, at: url, item: index, of: callIn) }
            }
            // Its reads hop to this actor, so none runs before its name is
            // recorded.
            guard let name = Self.name(of: receiver, item: index) else {
                named = false
                continue
            }
            callIn.name(index, name)
        }
        guard named else {
            complete(callIn)
            return nil
        }
        return callIn
    }

    /// The receiver's first file name, as its call-in left it, when it is one
    /// path component.
    private static func name(of receiver: any FilePromiseReceiving, item index: Int) -> String? {
        let fileNames = receiver.fileNames
        guard let first = fileNames.first, PathComponent.isValid(Data(first.utf8)) else {
            logger.log(.warning, "Promised item \(index, privacy: .public) named no file when called in")
            return nil
        }
        if fileNames.count > 1 {
            logger.log(
                .warning,
                "Promised item \(index, privacy: .public) names \(fileNames.count, privacy: .public) files; only the first goes to the host"
            )
        }
        return first
    }

    // MARK: - Reads

    /// One reader callback of item `index`: the file it was named by lands it;
    /// any other stays in the folder until the folder goes.
    ///
    /// The item is unavailable when its receiver names at most one file and
    /// the callback failed, or once the receiver has delivered every callback
    /// it owes without the named file — a failure from a receiver naming
    /// several cannot be paired with a file, since AppKit says to ignore its
    /// URL.
    private func read(_ landing: PromiseLanding, at url: URL, item index: Int, of callIn: CallIn) {
        let fileCount = callIn.receivers[index]?.fileNames.count ?? 0
        callIn.tally.record(from: index, naming: fileCount)
        defer { releaseIfDone(callIn) }
        guard let offered = callIn.offered[index] else { return }
        switch landing {
        case .failed(let reason) where fileCount <= 1:
            Self.logger.log(
                .warning, "Promised item \(index, privacy: .public) was not written: \(reason, privacy: .public)")
            return offered.landing.settle(.failure(Self.unavailable))
        case .landed where url.lastPathComponent == offered.name:
            return offered.landing.settle(.success(url))
        case .failed(let reason):
            Self.logger.log(
                .notice,
                "A file of promised item \(index, privacy: .public) was not written: \(reason, privacy: .public)")
        case .landed:
            Self.logger.log(
                .notice,
                "Promised item \(index, privacy: .public) wrote a file other than the one it was named by, which stays in the guest"
            )
        }
        guard callIn.tally.hasDeliveredAll(from: index) else { return }
        Self.logger.log(
            .warning,
            "Promised item \(index, privacy: .public) delivered every file without the one it was named by")
        offered.landing.settle(.failure(Self.unavailable))
    }

    private static var unavailable: WireError {
        WireError(.itemRepresentationUnavailable, debugDetail: "the promise's source did not write it")
    }

    // MARK: - Letting go

    /// The drag's offer ended: its folder goes once every read is in.
    func complete(_ callIn: CallIn) {
        callIn.offerDone = true
        releaseIfDone(callIn)
    }

    /// Removes the drag's folder once its offer ended and every read is in.
    private func releaseIfDone(_ callIn: CallIn) {
        guard callIn.offerDone, callIn.tally.isQuiesced,
            callIns.removeValue(forKey: ObjectIdentifier(callIn)) != nil
        else { return }
        let folder = callIn.folder
        removals.async {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Self.logger.log(
                    .warning,
                    "Could not remove the promises' folder: \(error.localizedDescription, privacy: .public)")
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
    /// A regular file or a folder, as the promise declared.
    case landed
    /// Nothing the promise declared; `reason` is log detail.
    case failed(String)

    /// Stats what a promise landed at `url`, which must be the kind its type
    /// declared: a host pulls a promise as the kind its offer named.
    init(at url: URL, error: (any Error)?, expectingFolder: Bool) {
        if let error {
            self = .failed(error.localizedDescription)
            return
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if expectingFolder {
            self = values?.isDirectory == true ? .landed : .failed("The promise of a folder wrote no folder")
        } else {
            self = values?.isRegularFile == true ? .landed : .failed("The promise of a file wrote no file")
        }
    }
}
