import UniformTypeIdentifiers
import os

extension UTType {
    /// The document type for Kernova VM bundles (`.kernova` packages).
    static let kernovaVM: UTType = {
        let identifier = "app.kernova.vm"
        guard let type = UTType(identifier) else {
            let logger = Logger(subsystem: "app.kernova", category: "UTType")
            logger.fault("UTType lookup failed for identifier '\(identifier, privacy: .public)'")
            assertionFailure("UTType lookup failed for identifier: \(identifier)")
            return .data
        }
        return type
    }()

    static let iso: UTType = resolvedFilenameExtension("iso")

    static let ipsw: UTType = resolvedFilenameExtension("ipsw")

    static let asif: UTType = resolvedFilenameExtension("asif")

    private static func resolvedFilenameExtension(_ ext: String, fallback: UTType = .data) -> UTType {
        guard let type = UTType(filenameExtension: ext) else {
            let logger = Logger(subsystem: "app.kernova", category: "UTType")
            logger.fault("UTType lookup failed for extension '\(ext, privacy: .public)'")
            assertionFailure("UTType lookup failed for extension: \(ext)")
            return fallback
        }
        return type
    }

    /// Disk image types offered in file picker panels for storage device attachment.
    ///
    /// `.raw` is deliberately mapped to `.data` because `UTType(filenameExtension: "raw")`
    /// resolves to `public.camera-raw-image` (digital camera photos), not raw disk images.
    static let diskImageTypes: [UTType] = {
        let logger = Logger(subsystem: "app.kernova", category: "UTType")
        let resolvedExtensions: [(ext: String, fallback: UTType)] = [
            ("iso", .diskImage), ("img", .data), ("asif", .data),
        ]
        // "raw" — forced to `.data` per the note above.
        let forcedFallbackExtensions: [UTType] = [.data]

        var types: [UTType] = [.diskImage]
        for (ext, fallback) in resolvedExtensions {
            guard let type = UTType(filenameExtension: ext) else {
                logger.fault("UTType lookup failed for known extension '\(ext, privacy: .public)'")
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
