import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaLogging
import KernovaWire

/// The file promises of drags the host takes out of the guest, received at
/// the catcher's delivering drop into each drag's staging folder of its own.
///
/// A drop receives its promises one of two ways. Where the drag's first
/// promised item offers its promised file URL, the drop sets the paste
/// location once and asks that item once (`Pasteboard.h`, "Pasteboard File
/// Promising", steps 4–5): a source such as Photos then writes every promise
/// of the drag into the folder, and each file is named by its arrival
/// (``awaitArrivals(_:into:taken:input:named:)``). Any other drop calls each
/// promise in through its own receiver (``callIn(_:receivers:taken:into:)``).
/// No vendor documents that asking one item delivers every item; it decides
/// only whether the drag delivers, never what is served: a file counts as
/// arrived only once a coordinated read of it is granted, and a drag whose
/// files do not all arrive names none.
///
/// A call-in outlives its take: sources write their files seconds after the
/// call-in, and a pull of a promise waits until its file has landed. The
/// folder goes once the drag's offer has ended and every file the promises
/// named has landed or failed — not before, since a host still pulling reads
/// from it and a source still writing writes into it.
///
/// A drag carries one item per promise, fixed when the host's Mac session
/// began, so a promise whose source names several files goes to the host as
/// its first: the item takes that file's name and lands as that file, and the
/// rest stay in the folder until it goes.
@MainActor
final class GuestDragPromises {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragPromises")

    /// The folder under the process staging root that every drag's own
    /// staging folder goes in.
    nonisolated static let stagingLabel = "agent-drag-out"

    /// One drag's received promises.
    @MainActor
    final class CallIn {
        let folder: URL
        /// Each promised item's name and landing, by its index in the drag.
        let offered: [Int: (name: String, landing: GuestDragLanding)]
        /// Every file the promises' sources still owe a report on.
        let pending: [Task<URL, any Error>]

        init(
            folder: URL, offered: [Int: (name: String, landing: GuestDragLanding)],
            pending: [Task<URL, any Error>]
        ) {
            self.folder = folder
            self.offered = offered
            self.pending = pending
        }
    }

    /// One drag whose source writes every promise into its folder, awaiting
    /// each promised item's file.
    @MainActor
    final class Arrivals {
        let folder: URL
        /// The promised items, by index in the drag, each with whether it
        /// lands as a folder.
        fileprivate let expected: [(index: Int, isFolder: Bool)]
        fileprivate var assigned: [Int: (name: String, landing: GuestDragLanding)] = [:]
        fileprivate var keys: Set<String>
        fileprivate var stopWatching: GuestDragCancel?
        fileprivate var named: ((CallIn) -> Void)?

        fileprivate init(folder: URL, expected: [(index: Int, isFolder: Bool)], keys: Set<String>) {
            self.folder = folder
            self.expected = expected
            self.keys = keys
        }

        /// Whether the drop is still awaiting files.
        fileprivate var isAwaiting: Bool { named != nil }

        fileprivate func stop() {
            named = nil
            stopWatching?()
            stopWatching = nil
        }
    }

    private let stagingRoot: ProcessStagingRoot

    /// Every call-in whose folder is still held.
    private var callIns: [ObjectIdentifier: CallIn] = [:]

    #if DEBUG
    /// Every folder removal started so far, for a test to await.
    private var removals: [Task<Void, Never>] = []
    #endif

    init(stagingRoot: ProcessStagingRoot) {
        self.stagingRoot = stagingRoot
    }

    /// A fresh, empty staging folder for one drag's promises, or nil when
    /// none could be made.
    func makeFolder() -> URL? {
        let folder = stagingRoot.url
            .appendingPathComponent(Self.stagingLabel, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try stagingRoot.createDirectory(at: folder)
            return folder
        } catch {
            Self.logger.log(
                .error,
                "Could not make a folder to receive promises into: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - The whole drop at once

    /// Awaits the promised items among `items` as their source writes them
    /// into `folder`, which the drop's paste location names, calling `named`
    /// once every one has a file.
    ///
    /// Each entry that appears in `folder` counts once a coordinated read of
    /// it is granted through `input`, and goes to the first promised item
    /// still waiting whose kind — folder or not — it has, named as it is,
    /// made unlike every name in `taken` and every name before it, ignoring
    /// case (`DragItems.nameKey(_:)`). An entry no waiting item takes stays in
    /// the folder until it goes.
    func awaitArrivals(
        _ items: [GuestDragItem], into folder: URL, taken: [String], input: any GuestDragInput,
        named: @escaping @MainActor (CallIn) -> Void
    ) -> Arrivals {
        let expected = items.indices.filter { items[$0].fileURL == nil }.map { ($0, items[$0].isDirectoryPromise) }
        let arrivals = Arrivals(
            folder: folder, expected: expected, keys: Set(taken.map { DragItems.nameKey(Data($0.utf8)) }))
        arrivals.named = named
        arrivals.stopWatching = input.watchEntries(in: folder) { [weak self, weak input, weak arrivals] urls in
            guard let input else { return }
            for url in urls {
                input.coordinateRead(of: url) { arrival in
                    guard let self, let arrivals else { return }
                    self.arrived(arrival, arrivals)
                }
            }
        }
        return arrivals
    }

    private func arrived(_ arrival: GuestDragArrival?, _ arrivals: Arrivals) {
        guard arrivals.isAwaiting, let arrival else { return }
        let name = arrival.url.lastPathComponent
        guard PathComponent.isValid(Data(name.utf8)),
            let index = arrivals.expected.first(where: {
                arrivals.assigned[$0.index] == nil && $0.isFolder == arrival.isFolder
            })?.index
        else {
            Self.logger.log(.notice, "A file arrived that no promised item of the drag takes; it stays in the folder")
            return
        }
        let landing = GuestDragLanding()
        landing.settle(.success(arrival.url))
        arrivals.assigned[index] = (Self.unlike(name, &arrivals.keys), landing)
        guard arrivals.assigned.count == arrivals.expected.count, let named = arrivals.named else { return }
        arrivals.stop()
        let callIn = CallIn(folder: arrivals.folder, offered: arrivals.assigned, pending: [])
        callIns[ObjectIdentifier(callIn)] = callIn
        named(callIn)
    }

    /// The drag ended before every promised item of `arrivals` had a file:
    /// it names none, and its folder goes.
    func abandon(_ arrivals: Arrivals) {
        guard arrivals.isAwaiting else { return }
        arrivals.stop()
        Self.logger.log(
            .notice,
            "The drag ended with \(arrivals.assigned.count, privacy: .public) of its \(arrivals.expected.count, privacy: .public) promised file(s) arrived; none is delivered"
        )
        remove(arrivals.folder, after: [])
    }

    // MARK: - Calling each promise in

    /// Calls in the promises among `items`, read off the drop in drag order as
    /// `receivers`, into `folder`; nil unless every one named a file as its
    /// call-in returned, the folder then going once their sources report.
    ///
    /// Each promised item is named by its receiver's first file, made unlike
    /// every name in `taken` and every name before it, ignoring case
    /// (`DragItems.nameKey(_:)`), as the host requires. The receivers pair
    /// with the drag's promised items in order; any other count leaves which
    /// is which unknown, so then none is called in.
    func callIn(
        _ items: [GuestDragItem], receivers: [any FilePromiseReceiving], taken: [String], into folder: URL
    ) -> CallIn? {
        let promised = items.indices.filter { items[$0].fileURL == nil }
        guard !promised.isEmpty, receivers.count == promised.count else {
            Self.logger.log(
                .warning,
                "The drag carries \(receivers.count, privacy: .public) promise(s) for \(promised.count, privacy: .public) promised item(s); calling none in"
            )
            remove(folder, after: [])
            return nil
        }
        var keys = Set(taken.map { DragItems.nameKey(Data($0.utf8)) })
        var pending: [Task<URL, any Error>] = []
        var offered: [Int: (name: String, landing: GuestDragLanding)] = [:]
        let queue = OperationQueue()
        for (index, receiver) in zip(promised, receivers) {
            let promise = CalledInFilePromise.callIn(receiver, into: folder, operationQueue: queue)
            pending += promise.files.map(\.landed)
            let first = promise.files[0]
            guard PathComponent.isValid(Data(first.name.utf8)) else {
                Self.logger.log(.warning, "Promised item \(index, privacy: .public) named no file when called in")
                continue
            }
            if promise.files.count > 1 {
                Self.logger.log(
                    .notice,
                    "Promised item \(index, privacy: .public) names \(promise.files.count, privacy: .public) files; the first goes to the host"
                )
            }
            let landing = GuestDragLanding()
            Self.settle(landing, from: first.landed, expectingFolder: items[index].isDirectoryPromise, item: index)
            offered[index] = (Self.unlike(first.name, &keys), landing)
        }
        let callIn = CallIn(folder: folder, offered: offered, pending: pending)
        callIns[ObjectIdentifier(callIn)] = callIn
        guard offered.count == promised.count else {
            complete(callIn)
            return nil
        }
        return callIn
    }

    /// `name`, or the first of `name 2`, `name 3`, … before its extension
    /// that no key in `keys` holds; the chosen name's key joins `keys`.
    private static func unlike(_ name: String, _ keys: inout Set<String>) -> String {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        var candidate = name
        var number = 2
        while !keys.insert(DragItems.nameKey(Data(candidate.utf8))).inserted {
            candidate = "\(stem) \(number)\(suffix)"
            number += 1
        }
        return candidate
    }

    /// Settles `landing` with the file `landed` delivers, once it is the kind
    /// the promise declared: a host pulls a promise as the kind its offer
    /// named.
    private static func settle(
        _ landing: GuestDragLanding, from landed: Task<URL, any Error>, expectingFolder: Bool, item index: Int
    ) {
        Task.detached {
            let result: Result<URL, WireError>
            do {
                let url = try await landed.value
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                let isKind = expectingFolder ? values?.isDirectory == true : values?.isRegularFile == true
                if !isKind {
                    logger.log(.warning, "Promised item \(index, privacy: .public) wrote another kind than it promised")
                }
                result = isKind ? .success(url) : .failure(unavailable)
            } catch {
                logger.log(
                    .warning,
                    "Promised item \(index, privacy: .public) was not written: \(error.localizedDescription, privacy: .public)"
                )
                result = .failure(unavailable)
            }
            landing.settle(result)
        }
    }

    nonisolated private static var unavailable: WireError {
        WireError(.itemRepresentationUnavailable, debugDetail: "the promise's source did not write it")
    }

    // MARK: - Letting go

    /// The drag's offer ended: its folder goes once every file its promises
    /// still owe has landed or failed.
    func complete(_ callIn: CallIn) {
        guard callIns.removeValue(forKey: ObjectIdentifier(callIn)) != nil else { return }
        remove(callIn.folder, after: callIn.pending)
    }

    private func remove(_ folder: URL, after pending: [Task<URL, any Error>]) {
        let removal = Task.detached {
            for file in pending { _ = try? await file.value }
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Self.logger.log(
                    .warning, "Could not remove the promises' folder: \(error.localizedDescription, privacy: .public)")
            }
        }
        #if DEBUG
        removals.append(removal)
        #else
        _ = removal
        #endif
    }

    #if DEBUG
    /// Test seam: returns once every folder removal started so far is done.
    func waitForFolderRemovalsForTesting() async {
        for removal in removals { await removal.value }
    }
    #endif
}
