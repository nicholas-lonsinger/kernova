import AppKit
import Foundation
import KernovaLogging

/// How clipboard staging goes: every pasteboard item naming a file in what goes is withdrawn whole first, on the
/// main actor, and only then is it removed, off it — so no item a write of this side placed ever names a staged
/// file that is gone.
///
/// - This process's own staging (``retire(_:then:)``, ``processEnding(_:)``): the withdrawal goes through the
///   publisher whose write the pasteboard still holds, which knows which of its types are data, so none of its
///   promises is fired.
/// - An exited process's (``retireAbandoned(_:then:)``): nothing of that process's is left to ask, so the items of
///   the pasteboard itself are read. Which process wrote one cannot be known; that it names a file about to go
///   can, and only such an item goes. A pasteboard that moved on to anything else names none, and is left alone.
public struct ClipboardStagingRetirement: StagedContentRetirement {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "ClipboardStagingRetirement")

    private let ledger: ClipboardWriteLedger
    private let pasteboard: @MainActor @Sendable () -> any ClipboardPasteboard

    /// Retirement withdrawing what the writes `ledger` records name, and what `pasteboard` holds of an exited
    /// process's: the general pasteboard, which is the one another process can have left a write on.
    public init(
        ledger: ClipboardWriteLedger = .shared,
        pasteboard: @escaping @MainActor @Sendable () -> any ClipboardPasteboard = { NSPasteboard.general }
    ) {
        self.ledger = ledger
        self.pasteboard = pasteboard
    }

    /// Withdraws every item a write of this process names under `directories` with, on the main actor, then runs
    /// `remove` off it.
    public func retire(_ directories: [URL], then remove: @escaping @Sendable () -> Void) {
        let ledger = ledger
        MainActorBridge.async {
            ledger.withdrawItems(namingFilesUnder: directories)
            DispatchQueue.global(qos: .utility).async(execute: remove)
        }
    }

    /// Withdraws every item of the pasteboard naming a file under `roots`, on the main actor, then runs `remove` off
    /// it.
    public func retireAbandoned(_ roots: [URL], then remove: @escaping @Sendable () -> Void) {
        let ledger = ledger
        let pasteboard = pasteboard
        MainActorBridge.async {
            let board = pasteboard()
            // A write of this process standing there names only this process's own staging.
            if !ledger.holdsWrite(on: board), let retraction = Self.withdrawItems(of: board, namingFilesUnder: roots) {
                Self.logger.log(
                    .notice,
                    "Withdrew the clipboard items naming an exited process's staging\(retraction == .keptPart ? ", the rest kept" : "", privacy: .public)"
                )
            }
            DispatchQueue.global(qos: .utility).async(execute: remove)
        }
    }

    /// Withdraws every item a write of this process names under `root` with, now.
    @MainActor public func processEnding(_ root: URL) {
        ledger.withdrawItems(namingFilesUnder: [root])
    }

    /// Withdraws, whole, every item of `pasteboard` naming a file under `roots` as its `public.file-url`, writing
    /// every other item again as the data it holds; nil when no item names one, which changes nothing and reads
    /// nothing but each item's `public.file-url`. An item left with nothing but its concealed marker goes too.
    @MainActor static func withdrawItems(
        of pasteboard: any ClipboardPasteboard, namingFilesUnder roots: [URL]
    ) -> ClipboardRetraction? {
        let items = pasteboard.items
        let naming = items.map { item in
            item.types.contains(.fileURL)
                && item.data(forType: .fileURL).map {
                    ClipboardPasteboardPublisher.names([(.fileURL, $0)], aFileUnder: roots)
                } == true
        }
        guard naming.contains(true) else { return nil }
        let marker = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI)
        let kept = zip(items, naming).compactMap { item, names -> [(type: NSPasteboard.PasteboardType, bytes: Data)]? in
            guard !names else { return nil }
            let data = item.types.compactMap { type in item.data(forType: type).map { (type: type, bytes: $0) } }
            return data.contains { $0.type != marker } ? data : nil
        }
        guard !kept.isEmpty else {
            pasteboard.clearContents()
            return .cleared
        }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeItems(kept.map { ClipboardWriteItem(data: $0, promised: [], provider: nil) }) else {
            return .cleared
        }
        return .keptPart
    }
}
