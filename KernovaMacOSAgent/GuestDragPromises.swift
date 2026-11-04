import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaLogging
import KernovaWire

/// The file promises of drags the host takes out of the guest, called in at
/// the catcher's delivering drop: each drag's staging folder, and the files
/// its promises still owe.
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

    /// One drag's called-in promises.
    @MainActor
    final class CallIn {
        let folder: URL
        /// Each promise as it was called in, by its item's index in the drag.
        let promises: [Int: CalledInFilePromise]
        /// Each promised item's name and landing, by the same index.
        let offered: [Int: (name: String, landing: GuestDragLanding)]

        init(
            folder: URL, promises: [Int: CalledInFilePromise],
            offered: [Int: (name: String, landing: GuestDragLanding)]
        ) {
            self.folder = folder
            self.promises = promises
            self.offered = offered
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

    // MARK: - Calling in

    /// Calls in the promises among `items`, read off the drop in drag order as
    /// `receivers`, into a staging folder of their own; nil unless every one
    /// named a file as its call-in returned.
    ///
    /// Each promised item is named by its receiver's first file, made unlike
    /// every name in `taken` and every name before it, ignoring case
    /// (`DragItems.nameKey(_:)`), as the host requires. The receivers pair
    /// with the drag's promised items in order; any other count leaves which
    /// is which unknown, so then none is called in.
    func callIn(_ items: [GuestDragItem], receivers: [any FilePromiseReceiving], taken: [String]) -> CallIn? {
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
        var keys = Set(taken.map { DragItems.nameKey(Data($0.utf8)) })
        var promises: [Int: CalledInFilePromise] = [:]
        var offered: [Int: (name: String, landing: GuestDragLanding)] = [:]
        for (index, receiver) in zip(promised, receivers) {
            let promise = CalledInFilePromise.callIn(receiver, into: folder)
            promises[index] = promise
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
        let callIn = CallIn(folder: folder, promises: promises, offered: offered)
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
    /// named has landed or failed.
    func complete(_ callIn: CallIn) {
        guard callIns.removeValue(forKey: ObjectIdentifier(callIn)) != nil else { return }
        let files = callIn.promises.values.flatMap(\.files)
        let folder = callIn.folder
        let removal = Task.detached {
            for file in files { _ = try? await file.landed.value }
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
