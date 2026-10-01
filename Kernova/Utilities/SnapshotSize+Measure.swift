import Darwin
import Foundation
import KernovaKit

extension SnapshotSize {
    /// Measures everything under `directory`, or `nil` when an allocated size
    /// can't be read; a directory that isn't there measures zero.
    ///
    /// Private bytes are read only where the volume clones files, and are
    /// `nil` when any file's can't be read.
    static func measure(directory: URL) -> SnapshotSize? {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return SnapshotSize(bytes: 0, privateBytes: nil)
        }
        guard
            let clones = try? directory.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
                .volumeSupportsFileCloning
        else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        var unreadable = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys,
                errorHandler: { _, _ in
                    unreadable = true
                    return false
                })
        else { return nil }
        var bytes: UInt64 = 0
        var privateBytes: UInt64? = clones ? 0 : nil
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                let isRegularFile = values.isRegularFile
            else { return nil }
            guard isRegularFile else { continue }
            guard let allocated = values.totalFileAllocatedSize else { return nil }
            bytes &+= UInt64(allocated)
            if let total = privateBytes {
                privateBytes = Self.privateBytes(of: url).map { total &+ $0 }
            }
        }
        return unreadable ? nil : SnapshotSize(bytes: bytes, privateBytes: privateBytes)
    }

    /// The bytes of `file` that no clone or volume snapshot shares
    /// (`getattrlist(2)`, `ATTR_CMNEXT_PRIVATESIZE`).
    static func privateBytes(of file: URL) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // u_int32_t length, attribute_set_t returned, off_t private size.
        let returnedOffset = MemoryLayout<UInt32>.size
        let sizeOffset = returnedOffset + MemoryLayout<attribute_set_t>.size
        var buffer = [UInt8](repeating: 0, count: sizeOffset + MemoryLayout<off_t>.size)
        let status = file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return getattrlist(
                path, &request, &buffer, buffer.count,
                UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> UInt64? in
            let returned = raw.loadUnaligned(fromByteOffset: returnedOffset, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let size = raw.loadUnaligned(fromByteOffset: sizeOffset, as: off_t.self)
            return size >= 0 ? UInt64(size) : nil
        }
    }
}
