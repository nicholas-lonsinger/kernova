import Foundation
import KernovaKit
import KernovaLogging

/// Where files dragged onto a VM display as *promises* — a Photos image, a Mail
/// attachment, a picture dragged out of a browser — are written before they are
/// offered to the guest.
///
/// A promise's bytes have to exist somewhere the guest's pull can read them, and
/// that pull comes after the drag is over, often long after: the guest serves one
/// drop at a time, so a batch queued behind a large one is not read until its
/// turn comes. Each drop gets a directory of its own, released by ``release(_:)``
/// once that drop settles — the drop's own end is the only thing that can tell a
/// queued drop from a stale one. An exited process's drops are reclaimed with its
/// whole ``ProcessStagingRoot`` by the next launch.
struct DropPromiseStaging {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "DropPromiseStaging")

    /// This process's root for promise drops.
    static let processRoot = ProcessStagingRoot(
        parent: FileManager.default.temporaryDirectory.appendingPathComponent(
            "DisplayDropPromises", isDirectory: true))

    /// The root every drop's directory sits under.
    let root: ProcessStagingRoot

    /// - Parameter root: ``processRoot`` in production.
    init(root: ProcessStagingRoot) {
        self.root = root
    }

    /// Removes one drop's directory, once nothing can read from it again.
    ///
    /// Static because a settled drop is named by its directory alone, and
    /// `VsockDropService` frees ones it never staged.
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
            #log(
                Self.logger, .warning,
                "Could not release a settled drop's staged files: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Creates an empty directory for one drop.
    ///
    /// `nil` when it cannot be created, which leaves the drop with nowhere to put
    /// the promised files and is reported as a drop that produced nothing.
    func makeDropDirectory() -> URL? {
        let directory = root.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try root.createDirectory(at: directory)
        } catch {
            #log(
                Self.logger, .error,
                "Could not stage a dropped file promise: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        return directory
    }
}
