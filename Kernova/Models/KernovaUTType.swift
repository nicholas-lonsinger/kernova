import UniformTypeIdentifiers
import os

extension UTType {
    /// The document type for Kernova VM bundles (`.kernova` packages).
    static let kernovaVM = UTType("com.kernova.vm")!

    /// Disk image types offered in file picker panels for storage device attachment.
    ///
    /// `.raw` is deliberately mapped to `.data` because `UTType(filenameExtension: "raw")`
    /// resolves to `public.camera-raw-image` (digital camera photos), not raw disk images.
    static let diskImageTypes: [UTType] = {
        let logger = Logger(subsystem: "com.kernova.app", category: "UTType")
        // Extensions where the system UTType correctly represents a disk image format.
        let resolvedExtensions: [(ext: String, fallback: UTType)] = [
            ("iso", .diskImage), ("img", .data), ("asif", .data),
        ]
        // Extensions where the system UTType is semantically wrong for disk images.
        // RATIONALE: "raw" maps to public.camera-raw-image on macOS, not raw disk images.
        // We use .data directly to avoid filtering by the wrong content type.
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
