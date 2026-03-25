import UniformTypeIdentifiers
import os

extension UTType {
    /// The document type for Kernova VM bundles (`.kernova` packages).
    static let kernovaVM = UTType("com.kernova.vm")!

    /// Disk image types offered in file picker panels for storage device attachment.
    static let diskImageTypes: [UTType] = {
        let logger = Logger(subsystem: "com.kernova.app", category: "UTType")
        let extensions: [(ext: String, fallback: UTType)] = [
            ("iso", .diskImage), ("img", .data), ("raw", .data), ("asif", .data),
        ]
        var types: [UTType] = [.diskImage]
        for (ext, fallback) in extensions {
            guard let type = UTType(filenameExtension: ext) else {
                logger.fault("UTType lookup failed for known extension '\(ext, privacy: .public)'")
                assertionFailure("UTType lookup failed for extension: \(ext)")
                types.append(fallback)
                continue
            }
            types.append(type)
        }
        return types
    }()
}
