import Darwin
import Foundation
import System

/// The one spelling the file system gives an object that exists.
///
/// Spellings that reach one directory can differ byte for byte: APFS matches
/// names without regard to case or Unicode normalization, and a symlink or the
/// `/System/Volumes/Data` firmlink is a second route to the same place. The
/// kernel's own path for the object is the same whichever spelling reached it.
public enum CanonicalPath {
    /// The kernel's path for the object at `url`: symlinks resolved, a firmlink
    /// folded into the path the root volume shows, and every name as it is
    /// stored on disk.
    ///
    /// Asked with `getattrlist(2)`, a metadata read the App Sandbox allows on
    /// every path. `F_GETPATH` answers the same but needs a descriptor, and
    /// opening one — `O_EVTONLY` included — is a data read the sandbox refuses
    /// wherever the process may not read files.
    ///
    /// - Throws: the `errno` the lookup failed with, `Errno.noSuchFileOrDirectory`
    ///   when nothing is at `url`.
    public static func of(_ url: URL) throws(Errno) -> String {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_FULLPATH)
        // The reply's length, the attribute's reference, then the path it
        // points at, which getattrlist(2) bounds at PATH_MAX.
        let referenceOffset = MemoryLayout<UInt32>.size
        var reply = [UInt8](
            repeating: 0,
            count: referenceOffset + MemoryLayout<attrreference_t>.size + Int(PATH_MAX))
        guard getattrlist(url.path, &request, &reply, reply.count, 0) == 0 else {
            throw Errno(rawValue: errno)
        }

        return reply.withUnsafeBytes { raw in
            let reference = raw.loadUnaligned(
                fromByteOffset: referenceOffset, as: attrreference_t.self)
            let start = referenceOffset + Int(reference.attr_dataoffset)
            // The length counts the terminating NUL.
            let end = start + Int(reference.attr_length) - 1
            return String(decoding: raw[start..<end], as: UTF8.self)
        }
    }
}
