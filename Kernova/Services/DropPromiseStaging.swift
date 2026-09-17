import Foundation
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
/// queued drop from a stale one. ``reclaimAll`` at launch is the crash backstop,
/// the way `ClipboardFileStaging` bounds a paste's.
struct DropPromiseStaging {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "DropPromiseStaging")

    /// The root every drop's directory sits under.
    let root: URL

    /// - Parameter tempRoot: the directory the root sits in. The app reclaims
    ///   that root whole at launch and every test-host process shares one app
    ///   container, so a test stages under a root of its own: another host can
    ///   launch while a test is mid-drag.
    init(tempRoot: URL = FileManager.default.temporaryDirectory) {
        root = tempRoot.appendingPathComponent("DisplayDropPromises", isDirectory: true)
    }

    /// Removes every drop's staged files, crash orphans included.
    ///
    /// Call once at process launch, before anything stages a drop: an earlier
    /// run's drops ended with it, so nothing left under the root is still being
    /// pulled from. A drop this run stages is freed by ``release(_:)`` instead.
    static func reclaimAll(tempRoot: URL = FileManager.default.temporaryDirectory) {
        do {
            try FileManager.default.removeItem(at: Self(tempRoot: tempRoot).root)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was staged last run.
        } catch {
            #log(
                Self.logger, .warning,
                "Could not reclaim staged drop files: \(error.localizedDescription, privacy: .public)"
            )
        }
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
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
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
