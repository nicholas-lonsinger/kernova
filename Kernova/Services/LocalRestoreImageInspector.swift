import Foundation
import KernovaKit
import Virtualization
import os

/// Reads a restore image already on disk through Virtualization.
///
/// Used before adopting a file the wizard did not download itself, so the
/// version shown on the Review step is the image's own rather than the one the
/// user happened to have selected when the file was found.
struct LocalRestoreImageInspector: LocalRestoreImageInspecting {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "LocalRestoreImageInspector")

    func inspect(_ url: URL) async throws -> InspectedRestoreImage {
        // VZ rejects a path containing a symlink in any component and reports it
        // as a missing file, so it is only ever handed resolved URLs.
        let resolved = url.resolvingSymlinksInPath()
        let image: VZMacOSRestoreImage
        do {
            image = try await VZMacOSRestoreImage.image(from: resolved)
        } catch {
            Self.logger.warning(
                "Could not read restore image at '\(resolved.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw LocalRestoreImageError.unreadable
        }

        let version = image.operatingSystemVersion
        let sizeBytes = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { $0 }
            .map(UInt64.init)
        let inspected = InspectedRestoreImage(
            version: KernovaOSVersion.displayString(version),
            build: image.buildVersion,
            isSupportedOnThisHost: image.mostFeaturefulSupportedConfiguration != nil,
            sizeBytes: sizeBytes
        )
        Self.logger.info(
            "Inspected local restore image: \(inspected.summary, privacy: .public), supported=\(inspected.isSupportedOnThisHost, privacy: .public)"
        )
        return inspected
    }
}
