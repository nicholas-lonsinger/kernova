import KernovaLogging
import UniformTypeIdentifiers

extension UTType {
    /// The document type for Kernova VM bundles (`.kernova` packages), as the
    /// app's `Info.plist` exports it — `VMBundleFile.supportedContentTypes`
    /// writes the same declaration out for the App Intents extractor.
    package static let kernovaVM = UTType(exportedAs: "app.kernova.vm")

    package static let iso: UTType = resolvedFilenameExtension("iso")

    package static let ipsw: UTType = resolvedFilenameExtension("ipsw")

    package static let asif: UTType = resolvedFilenameExtension("asif")

    private static func resolvedFilenameExtension(_ ext: String, fallback: UTType = .data) -> UTType {
        guard let type = UTType(filenameExtension: ext) else {
            let logger = KernovaLogger(subsystem: "app.kernova", category: "UTType")
            logger.log(.fault, "UTType lookup failed for extension '\(ext, privacy: .public)'")
            assertionFailure("UTType lookup failed for extension: \(ext)")
            return fallback
        }
        return type
    }

    /// Disk image types offered in file picker panels for storage device attachment.
    ///
    /// `.raw` maps to `.data` because `UTType(filenameExtension: "raw")` resolves to
    /// `public.camera-raw-image` (digital camera photos), not raw disk images.
    package static let diskImageTypes: [UTType] = {
        let logger = KernovaLogger(subsystem: "app.kernova", category: "UTType")
        let resolvedExtensions: [(ext: String, fallback: UTType)] = [
            ("iso", .diskImage), ("img", .data), ("asif", .data),
        ]
        // "raw" — forced to `.data` per the note above.
        let forcedFallbackExtensions: [UTType] = [.data]

        var types: [UTType] = [.diskImage]
        for (ext, fallback) in resolvedExtensions {
            guard let type = UTType(filenameExtension: ext) else {
                logger.log(.fault, "UTType lookup failed for known extension '\(ext, privacy: .public)'")
                assertionFailure("UTType lookup failed for extension: \(ext)")
                types.append(fallback)
                continue
            }
            types.append(type)
        }
        types.append(contentsOf: forcedFallbackExtensions)
        return types
    }()
}
