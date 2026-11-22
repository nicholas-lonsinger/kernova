#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The checkout the tests run from, where a test finds the files checked in for it.
///
/// `KERNOVA_SOURCE_ROOT` names it: the test plan sets it for xcodebuild, and `with_package_pins`
/// (Tools/lib/package-pins.sh) for SwiftPM. A `#filePath` names no file in a `make` build, which compiles every
/// path under the checkout as a placeholder (Tools/lib/xcodebuild-flags.sh).
public enum SourceTree {
    /// The file or directory at `path`, `/`-separated from the checkout's root.
    public static func url(_ path: String) -> URL {
        guard let root = ProcessInfo.processInfo.environment["KERNOVA_SOURCE_ROOT"], !root.isEmpty else {
            fatalError(
                "KERNOVA_SOURCE_ROOT is unset: the test plan sets it for xcodebuild, and with_package_pins "
                    + "(Tools/lib/package-pins.sh) for swift test")
        }
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
    }
}
