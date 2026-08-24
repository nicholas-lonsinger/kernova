import Foundation
import os

/// Where files dragged onto a VM display as *promises* — a Photos image, a Mail
/// attachment, a picture dragged out of a browser — are written before they are
/// offered to the guest.
///
/// A promise's bytes have to exist somewhere the guest's pull can read them, and
/// that pull comes after the drag is over, often long after: the guest serves one
/// drop at a time, so a batch queued behind a large one is not read until its
/// turn comes. Each drop gets a directory of its own, released by ``release(_:)``
/// once that drop settles — the drop's own end is the only thing that can tell a
/// queued drop from a stale one. ``reclaimAll`` at launch is the crash backstop,
/// the way `ClipboardFileStaging` bounds a paste's.
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
    /// Call once at process launch, before anything stages a drop: an earlier
    /// run's drops ended with it, so nothing left under the root is still being
    /// pulled from. A drop this run stages is freed by ``release(_:)`` instead.
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

    /// Removes one drop's directory, once nothing can read from it again.
    ///
    /// Idempotent, and silent about a directory that is already gone: the drag
    /// that never reached an offer and the drop the guest finished both end
    /// here, and either can have removed it first.
    static func release(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // Already released.
        } catch {
            logger.warning(
                "Could not release a settled drop's staged files: \(error.localizedDescription, privacy: .public)"
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
