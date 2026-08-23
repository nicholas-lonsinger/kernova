import Foundation
import os

/// Where files dragged onto a VM display as *promises* — a Photos image, a Mail
/// attachment, a picture dragged out of a browser — are written before they are
/// offered to the guest.
///
/// A promise's bytes have to exist somewhere the guest's pull can read them, and
/// that pull comes after the drag is over, often long after: the guest serves one
/// drop at a time. So a drop's directory cannot be deleted when the gesture ends.
/// Each drop gets one of its own and the newest ``retainedDrops`` are kept — the
/// retention `ClipboardFileStaging` uses for a paste's staged files — so a
/// directory left behind by an earlier run of the app is reclaimed by the next
/// drop that stages anything.
enum DropPromiseStaging {
    /// How many drops' staged files are kept, newest first.
    static let retainedDrops = 3

    private static let logger = Logger(subsystem: "app.kernova", category: "DropPromiseStaging")

    /// The root every drop's directory sits under, inside the app container.
    static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayDropPromises", isDirectory: true)
    }

    /// Creates an empty directory for one drop, reclaiming all but the newest
    /// ``retainedDrops`` that came before it.
    ///
    /// `nil` when it cannot be created, which leaves the drop with nowhere to put
    /// the promised files and is reported as a drop that produced nothing.
    static func makeDropDirectory() -> URL? {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error(
                "Could not stage a dropped file promise: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        reclaimOlderDrops(keeping: directory)
        return directory
    }

    /// Removes the staged files of every drop but the newest ``retainedDrops``.
    private static func reclaimOlderDrops(keeping newest: URL) {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles])
        else { return }
        let dated = entries.map { url in
            (
                url,
                (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    ?? Date.distantPast
            )
        }
        let stale = dated.sorted { $0.1 > $1.1 }.dropFirst(retainedDrops).map(\.0)
        for url in stale where url != newest {
            do {
                try manager.removeItem(at: url)
            } catch {
                logger.warning(
                    "Could not reclaim staged drop files: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
