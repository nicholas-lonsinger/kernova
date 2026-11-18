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

/// What publishing a peer's offer (``ClipboardPasteboardPublisher/publish(_:concealed:pasteCeiling:puller:serving:onReleased:)``)
/// did to the pasteboard.
public enum ClipboardOfferPublishOutcome: Equatable, Sendable {
    /// The offer promises nothing the pasteboard carries: the pasteboard is untouched.
    case nothingToWrite
    /// The offer is files alone, over the paste ceiling `limitBytes`: refused whole, the pasteboard untouched.
    case tooLarge(limitBytes: Int)
    /// The pasteboard holds the offer whole.
    case written
    /// The pasteboard holds the offer without its `count` files, which are over the paste ceiling `limitBytes`.
    case writtenWithoutFiles(count: Int, limitBytes: Int)
    /// The pasteboard refused the write: nothing of the offer was placed, and what it held is gone.
    case writeFailed
}

extension ClipboardPasteboardPublisher {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardPasteboardPublisher")

    /// The longest a paste's provider holds its thread for a pull: 120 s, when
    /// `NSPasteboard.dataForType(_:)` abandons a promise, and past Finder's
    /// 60 s (docs/research/2026-07-27-pasteboard-promise-deadlines.md). By
    /// then the reader has given up, so the provider answering nothing is all
    /// that is left to do.
    nonisolated static let pasteRequesterDeadline: TimeInterval = 120

    /// Publishes a peer's offer as its ``ClipboardPromisePolicy/writePlan(_:limit:)`` within `limitBytes` decides:
    /// one pasteboard item per offered item, every type promised and pulled through `puller` only when a paste
    /// asks for it. Files over the ceiling are left out, and an offer that is nothing else is not written.
    ///
    /// A concealed offer marks each item with `org.nspasteboard.ConcealedType`. The write serves the offer
    /// `token`, so ``retractWrite(servingOffer:withdrawing:)`` withdraws it once that offer ends; `onReleased`
    /// runs once the write no longer stands (``write(_:source:onReleased:)``).
    public func publish(
        _ items: [OfferedItem], concealed: Bool, pasteCeiling limitBytes: Int, puller: any ClipboardItemPulling,
        serving token: Data, onReleased: (@MainActor @Sendable () -> Void)? = nil
    ) -> ClipboardOfferPublishOutcome {
        let plan = ClipboardPromisePolicy.writePlan(items, limit: limitBytes)
        let filesLeftOut: Int
        switch plan {
        case .tooLarge:
            Self.logger.log(
                .notice, "An offer's files are over the \(limitBytes, privacy: .public)-byte paste ceiling: not written"
            )
            return .tooLarge(limitBytes: limitBytes)
        case .whole: filesLeftOut = 0
        case .withoutFiles(let count): filesLeftOut = count
        }
        let specs = Self.itemSpecs(
            for: items, concealed: concealed, servingFileURLs: plan.servesFileURLs, puller: puller)
        guard !specs.isEmpty else {
            Self.logger.log(.notice, "An offer promises nothing a pasteboard carries: not written")
            return .nothingToWrite
        }
        let source = ClipboardWriteSource(
            offer: token, items: items, concealed: concealed, servingFileURLs: plan.servesFileURLs, puller: puller)
        guard write(specs, source: source, onReleased: onReleased) else {
            Self.logger.log(.error, "The pasteboard refused an offer's write")
            return .writeFailed
        }
        guard filesLeftOut == 0 else {
            Self.logger.log(
                .notice,
                "An offer's \(filesLeftOut, privacy: .public) file(s) are over the \(limitBytes, privacy: .public)-byte paste ceiling: written without them"
            )
            return .writtenWithoutFiles(count: filesLeftOut, limitBytes: limitBytes)
        }
        return .written
    }

    /// The item specs promising `items`, as ``publish(_:concealed:pasteCeiling:puller:serving:onReleased:)``
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
    /// its main-thread wait from `eventLoopWait`.
    nonisolated static func itemSpecs(
        for items: [OfferedItem], concealed: Bool, servingFileURLs: Bool = true, puller: any ClipboardItemPulling,
        eventLoopWait: @escaping @Sendable () -> NestedEventLoopWait?
    ) -> [ItemSpec] {
        // The marker is written as data, so it stays with whatever of the item a retraction keeps.
        let markers: [(type: String, bytes: Data)] =
            concealed ? [(ClipboardSnapshotPolicy.concealedMarkerUTI, Data())] : []
        return items.enumerated().compactMap { index, item -> ItemSpec? in
            let promised = ClipboardPromisePolicy.promisedTypes(for: item, servingFileURLs: servingFileURLs)
            guard !promised.isEmpty else { return nil }
            let routes = Dictionary(uniqueKeysWithValues: promised.map { ($0.pasteboardType, $0) })
            return ItemSpec(data: markers, types: promised.map(\.pasteboardType)) { type in
                guard let route = routes[type] else { return nil }
                guard route.isFileURL else {
                    return held(eventLoopWait) {
                        puller.pullBytes(item: index, representation: route.representation, completion: $0)
                    }
                }
                return held(eventLoopWait) {
                    puller.pullFile(item: index, representation: route.representation, completion: $0)
                }
                .map { Data($0.absoluteString.utf8) }
            }
        }
    }

    /// Holds the provider's thread while the pull `start` begins runs to its
    /// completion, as ``ThreadHold/Wait`` holds it, for no longer than ``pasteRequesterDeadline``.
    ///
    /// - Returns: what the pull completed with; nil once the deadline passed first,
    ///   the pull running on, or without starting it on the main thread where
    ///   no event-loop wait is available.
    nonisolated private static func held<Value: Sendable>(
        _ eventLoopWait: () -> NestedEventLoopWait?,
        start: (_ completion: @escaping @Sendable (Value?) -> Void) -> Void
    ) -> Value? {
        guard let wait = ThreadHold.Wait(eventLoop: eventLoopWait()) else {
            logger.log(.notice, "A paste fired on the main thread outside its run loop's base; nothing pulled")
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
        let deadline = DispatchTime.now() + pasteRequesterDeadline
        guard let value = wait.hold(deadline: deadline, until: { completed.withLock { $0 } }) else {
            logger.log(
                .notice,
                "A paste gave up on its pull after \(pasteRequesterDeadline, privacy: .public) s; the pull runs on")
            return nil
        }
        return value
    }
}
