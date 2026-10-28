import Foundation
import KernovaLogging

/// The user's Downloads folder, where every image the app downloads lands.
package enum UserDownloads {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "UserDownloads")

    /// The folder, as the system names it.
    ///
    /// Asks the system for the Downloads location rather than assuming a
    /// home-relative layout: under the sandbox this resolves through the
    /// container's `Downloads` symlink, which the downloads.read-write
    /// entitlement covers — no save panel or bookmark needed.
    package static var url: URL {
        guard
            let downloads = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask
            ).first
        else {
            logger.log(.fault, "No Downloads directory in userDomainMask")
            assertionFailure("FileManager returned no Downloads directory")
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
        }
        return downloads
    }
}
