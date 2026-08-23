import Foundation
import os

/// Where files dragged onto a VM display as *promises* — a Photos image, a Mail
/// attachment, a picture dragged out of a browser — are written before they are
/// offered to the guest.
///
/// A promise's bytes have to exist somewhere the guest's pull can read them, and
/// that pull comes after the drag is over, often long after: the guest serves one
/// drop at a time, so a batch queued behind a large one is not read until its
/// turn comes. Each drop gets a directory of its own, and nothing this process
/// staged is reclaimed while it runs — a drop still queued is indistinguishable
/// from a stale one by anything a later drop can see. ``reclaimAll`` at launch is
/// what bounds the space, the way `ClipboardFileStaging` bounds a paste's.
enum DropPromiseStaging {
    private static let logger = Logger(subsystem: "app.kernova", category: "DropPromiseStaging")

    /// The root every drop's directory sits under, inside the app container.
    ///
    /// `tempRoot` is the seam a test stages under a root of its own, so the
    /// launch reclaim never runs against files another suite is writing.
    static func root(tempRoot: URL = FileManager.default.temporaryDirectory) -> URL {
        tempRoot.appendingPathComponent("DisplayDropPromises", isDirectory: true)
    }

    /// Removes every drop's staged files, crash orphans included.
    ///
    /// Call once at process launch, before anything stages a drop: no earlier
    /// run's guest can still be pulling, and no later moment can tell a queued
    /// drop from an abandoned one.
    static func reclaimAll(tempRoot: URL = FileManager.default.temporaryDirectory) {
        do {
            try FileManager.default.removeItem(at: root(tempRoot: tempRoot))
        } catch CocoaError.fileNoSuchFile {
            // Nothing was staged last run.
        } catch {
            logger.warning(
                "Could not reclaim staged drop files: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Creates an empty directory for one drop.
    ///
    /// `nil` when it cannot be created, which leaves the drop with nowhere to put
    /// the promised files and is reported as a drop that produced nothing.
    static func makeDropDirectory(tempRoot: URL = FileManager.default.temporaryDirectory) -> URL? {
        let directory = root(tempRoot: tempRoot)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error(
                "Could not stage a dropped file promise: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        return directory
    }
}
