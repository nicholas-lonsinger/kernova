import Foundation
import KernovaKit

extension MacOSVersion {
    /// Whether a guest at this version can run on the given host.
    ///
    /// Virtualization refuses a guest newer than the host, and the framework's
    /// own answer is only available after the image is downloaded — it comes
    /// from `VZMacOSRestoreImage.loadFileURL`, which takes a local file.
    func isSupported(onHost host: OperatingSystemVersion) -> Bool {
        self <= MacOSVersion(host)
    }
}
