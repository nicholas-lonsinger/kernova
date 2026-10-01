import Darwin
import Foundation

/// The bytes a directory's files hold that nothing else shares — the space
/// freed once they are deleted and the Trash is emptied.
enum PrivateBytes {
    /// The private bytes of everything under `directory` — zero when nothing
    /// is there — or `nil` when they can't be read.
    ///
    /// On a volume that clones, each file counts only its private blocks — the
    /// ones no clone or volume snapshot shares — so a block a snapshot shares
    /// with the VM's disks or another snapshot is not counted. Elsewhere
    /// nothing can be shared and the allocated size is exact.
    static func of(directory: URL) -> UInt64? {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return 0
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
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                let isRegularFile = values.isRegularFile
            else { return nil }
            guard isRegularFile else { continue }
            let bytes =
                clones
                ? of(file: url)
                : values.totalFileAllocatedSize.map(UInt64.init)
            guard let bytes else { return nil }
            total &+= bytes
        }
        return unreadable ? nil : total
    }

    /// The bytes of `file` that no clone or volume snapshot shares
    /// (`getattrlist(2)`, `ATTR_CMNEXT_PRIVATESIZE`).
    static func of(file: URL) -> UInt64? {
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
