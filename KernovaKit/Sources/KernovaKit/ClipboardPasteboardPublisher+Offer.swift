import AppKit
import Foundation
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// Pulls a peer's offered representations when a paste asks for them.
///
/// Each call starts a pull and returns without waiting for it: the publisher
/// holds the paste's thread until `completion` runs, on the main thread by
/// running its event loop, never by parking it (``ThreadHold/Wait``), and for
/// no longer than ``ClipboardPasteboardPublisher/pasteRequesterDeadline``,
/// after which the paste gets nothing and the pull runs on.
/// `completion` runs exactly once, on any thread, possibly before the call
/// returns. The puller ends every pull it starts: a pull that stalls still
/// ends with its offer.
public protocol ClipboardItemPulling: Sendable {
    /// Starts pulling the INLINE representation `representation` of item
    /// `item`; `completion` gets its bytes, or nil when the pull failed.
    func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void)

    /// Starts pulling the FILE or FOLDER representation `representation` of
    /// item `item`; `completion` gets the URL it landed at, under the name the
    /// receiver chose, or nil when the pull failed.
    func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void)
}

extension ClipboardPasteboardPublisher {
    nonisolated private static let pullLogger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardPasteboardPublisher")

    /// The longest a paste's provider holds its thread for a pull: 120 s, when
    /// `NSPasteboard.dataForType(_:)` abandons a promise, and past Finder's
    /// 60 s (docs/research/2026-07-27-pasteboard-promise-deadlines.md). By
    /// then the reader has given up, so the provider answering nothing is all
    /// that is left to do.
    nonisolated static let pasteRequesterDeadline: TimeInterval = 120

    /// Publishes a peer's offer: one pasteboard item per offered item, every
    /// type promised and pulled through `puller` only when a paste asks for it.
    ///
    /// `servingFileURLs` false withholds `public.file-url`, as a paste over
    /// the cap requires. A concealed offer marks each item with
    /// `org.nspasteboard.ConcealedType`. The write serves the offer `token`, so
    /// ``retractWrite(servingOffer:)`` withdraws it once that offer ends.
    @discardableResult
    public func publish(
        _ items: [OfferedItem], concealed: Bool, servingFileURLs: Bool = true, puller: any ClipboardItemPulling,
        servingOffer token: Data
    ) -> Bool {
        write(
            Self.itemSpecs(for: items, concealed: concealed, servingFileURLs: servingFileURLs, puller: puller),
            servingOffer: token)
    }

    /// Writes a peer's copy: each kept INLINE representation as the data
    /// `landed` holds for it, now, and each FILE or FOLDER promised through
    /// `puller`, so only files transfer when pasted.
    ///
    /// The write serves the copy `token`, and `onReleased` runs once the
    /// pasteboard is done with every file it promised. Returns whether the
    /// pasteboard took the write, and whether it promised anything.
    public func publishCopy(
        _ items: [OfferedItem], concealed: Bool, servingFileURLs: Bool, landed: (_ item: Int, _ rep: Int) -> Data?,
        puller: any ClipboardItemPulling, servingOffer token: Data,
        onReleased: @escaping @MainActor @Sendable () -> Void
    ) -> (written: Bool, promised: Bool) {
        let specs = Self.copySpecs(
            for: items, concealed: concealed, servingFileURLs: servingFileURLs, landed: landed, puller: puller,
            eventLoopWait: { NestedEventLoopWait.current() })
        guard !specs.isEmpty else { return (false, false) }
        let promised = specs.contains { !$0.types.isEmpty }
        return (write(specs, servingOffer: token, onReleased: onReleased), promised)
    }

    /// The item specs ``publishCopy(_:concealed:servingFileURLs:landed:puller:servingOffer:onReleased:)``
    /// writes. A type whose landed bytes are missing is left off its item, and an item left with nothing is
    /// dropped.
    nonisolated static func copySpecs(
        for items: [OfferedItem], concealed: Bool, servingFileURLs: Bool, landed: (Int, Int) -> Data?,
        puller: any ClipboardItemPulling, holdLimit: TimeInterval = pasteRequesterDeadline,
        eventLoopWait: @escaping @Sendable () -> NestedEventLoopWait?
    ) -> [ItemSpec] {
        items.enumerated().compactMap { index, item -> ItemSpec? in
            var data: [(type: String, bytes: Data)] = []
            var files: [Int] = []
            for promised in ClipboardPromisePolicy.promisedTypes(for: item, servingFileURLs: servingFileURLs) {
                if promised.isFileURL {
                    files.append(promised.representation)
                } else if let bytes = landed(index, promised.representation) {
                    data.append((promised.pasteboardType, bytes))
                }
            }
            guard !data.isEmpty || !files.isEmpty else { return nil }
            if concealed { data.append((ClipboardSnapshotPolicy.concealedMarkerUTI, Data())) }
            guard let file = files.first else { return ItemSpec(data: data, types: []) { _ in nil } }
            return ItemSpec(data: data, types: [ItemSpec.fileURLType]) { type in
                guard type == ItemSpec.fileURLType else { return nil }
                return held(eventLoopWait, for: holdLimit) {
                    puller.pullFile(item: index, representation: file, completion: $0)
                }
                .map { Data($0.absoluteString.utf8) }
            }
        }
    }

    /// The item specs promising `items`, as ``publish(_:concealed:servingFileURLs:puller:)``
    /// writes them.
    ///
    /// An item none of whose representations is kept is left out, so a paste
    /// finds no flavor rather than one serving nothing.
    nonisolated public static func itemSpecs(
        for items: [OfferedItem], concealed: Bool, servingFileURLs: Bool = true, puller: any ClipboardItemPulling
    ) -> [ItemSpec] {
        itemSpecs(
            for: items, concealed: concealed, servingFileURLs: servingFileURLs, puller: puller,
            eventLoopWait: { NestedEventLoopWait.current() })
    }

    /// ``itemSpecs(for:concealed:servingFileURLs:puller:)``, each fire taking
    /// its main-thread wait from `eventLoopWait` and holding for a pull no
    /// longer than `holdLimit`.
    nonisolated static func itemSpecs(
        for items: [OfferedItem], concealed: Bool, servingFileURLs: Bool = true, puller: any ClipboardItemPulling,
        holdLimit: TimeInterval = pasteRequesterDeadline,
        eventLoopWait: @escaping @Sendable () -> NestedEventLoopWait?
    ) -> [ItemSpec] {
        let markers = concealed ? [ClipboardSnapshotPolicy.concealedMarkerUTI] : []
        return items.enumerated().compactMap { index, item -> ItemSpec? in
            let promised = ClipboardPromisePolicy.promisedTypes(for: item, servingFileURLs: servingFileURLs)
            guard !promised.isEmpty else { return nil }
            let routes = Dictionary(uniqueKeysWithValues: promised.map { ($0.pasteboardType, $0) })
            let markerSet = Set(markers)
            return ItemSpec(types: promised.map(\.pasteboardType) + markers) { type in
                if markerSet.contains(type) { return Data() }
                guard let route = routes[type] else { return nil }
                guard route.isFileURL else {
                    return held(eventLoopWait, for: holdLimit) {
                        puller.pullBytes(item: index, representation: route.representation, completion: $0)
                    }
                }
                return held(eventLoopWait, for: holdLimit) {
                    puller.pullFile(item: index, representation: route.representation, completion: $0)
                }
                .map { Data($0.absoluteString.utf8) }
            }
        }
    }

    /// Holds the provider's thread while the pull `start` begins runs to its
    /// completion, as ``ThreadHold/Wait`` holds it, for no longer than `limit`.
    ///
    /// - Returns: what the pull completed with; nil once `limit` passed first,
    ///   the pull running on, or without starting it on the main thread where
    ///   no event-loop wait is available.
    nonisolated private static func held<Value: Sendable>(
        _ eventLoopWait: () -> NestedEventLoopWait?, for limit: TimeInterval,
        start: (_ completion: @escaping @Sendable (Value?) -> Void) -> Void
    ) -> Value? {
        guard let wait = ThreadHold.Wait(eventLoop: eventLoopWait()) else {
            pullLogger.log(.notice, "A paste fired on the main thread outside its run loop's base; nothing pulled")
            return nil
        }
        let completed = Locked<Value??>(nil)
        start { value in
            let isFirst = completed.withLock { completed -> Bool in
                guard case .none = completed else { return false }
                completed = .some(value)
                return true
            }
            if isFirst { wait.wake() }
        }
        let deadline = DispatchTime.now() + limit
        guard let value = wait.hold(deadline: deadline, until: { completed.withLock { $0 } }) else {
            pullLogger.log(.notice, "A paste gave up on its pull after \(limit, privacy: .public) s; the pull runs on")
            return nil
        }
        return value
    }
}
