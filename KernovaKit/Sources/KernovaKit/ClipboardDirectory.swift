import Foundation

/// A folder (or OS package) as a clipboard representation offers it.
public enum ClipboardDirectory {
    /// UTI for a directory representation.
    public static let uti = "public.folder"

    /// Upper bound on how many entries the estimate walk visits before stopping,
    /// so a pathological tree (or a symlink cycle — the estimate's enumerator
    /// follows links) can't spin unbounded.
    private static let estimateEntryCap = 500_000

    /// A stat-walk size estimate (sum of regular-file sizes) for a source folder.
    ///
    /// The folder representation's offered size, which the receiver's paste cap
    /// and free-space preflight gate on.
    public static func estimatedByteCount(at root: URL) -> Int {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
        else { return 0 }
        var total = 0
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count > estimateEntryCap { break }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            {
                total &+= values.fileSize ?? 0
            }
        }
        return total
    }
}
