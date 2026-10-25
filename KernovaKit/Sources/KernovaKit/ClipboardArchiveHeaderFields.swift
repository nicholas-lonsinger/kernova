import AppleArchive
import Darwin

// Entry headers through AppleArchive's C API, whose string fields are raw
// bytes. The Swift API's `ArchiveHeader.Field.string` takes and returns a
// `String`, which puts U+FFFD in place of every byte that is not UTF-8
// (docs/research/2026-10-23-applearchive-extract-semantics.md, finding 3) —
// and on SMB, NFS and exFAT a name need not be.

private func fieldKey(_ name: String) -> __AAFieldKey {
    let bytes = Array(name.utf8)
    precondition(bytes.count == 3, "an archive field key is three characters: \(name)")
    var key = __AAFieldKey()
    key.ikey = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
    return key
}

/// An entry header built field by field, in the order the fields are
/// appended.
package final class ClipboardArchiveHeaderBuilder {
    /// A header's encoding is at most `UInt16.max` bytes, and every field but
    /// the strings encodes in under this many together.
    private static let nonStringFieldBound = 256

    private let header: __AAHeader
    /// Whether a field was refused, which leaves the header without it.
    private var refused = false

    /// Whether string fields carrying `byteCount` bytes in all fit a header.
    static func fits(stringBytes byteCount: Int) -> Bool {
        nonStringFieldBound + byteCount <= Int(UInt16.max)
    }

    /// An empty header, or `nil` when AppleArchive cannot allocate one.
    package init?() {
        guard let header = __AAHeaderCreate() else { return nil }
        self.header = header
    }

    deinit { __AAHeaderDestroy(header) }

    package func append(uint value: UInt64, key: String) {
        record(__AAHeaderSetFieldUInt(header, UInt32.max, fieldKey(key), value))
    }

    /// Appends a string field carrying `bytes` exactly.
    package func append(string bytes: [UInt8], key: String) {
        // Terminated, so even an empty string has a non-null pointer.
        let terminated = bytes.map { CChar(bitPattern: $0) } + [0]
        record(
            terminated.withUnsafeBufferPointer { chars in
                guard let base = chars.baseAddress else { return -1 }
                return __AAHeaderSetFieldString(header, UInt32.max, fieldKey(key), base, bytes.count)
            })
    }

    package func append(timespec value: timespec, key: String) {
        var value = value
        record(__AAHeaderSetFieldTimespec(header, UInt32.max, fieldKey(key), &value))
    }

    /// Appends a blob field declaring `size` bytes of payload.
    package func append(blobSize size: UInt64, key: String) {
        record(__AAHeaderSetFieldBlob(header, UInt32.max, fieldKey(key), size))
    }

    /// The header, or `nil` when a field was refused or the encoding does not
    /// parse.
    package func make() -> ArchiveHeader? {
        guard !refused, let encoded = __AAHeaderGetEncodedData(header) else { return nil }
        return ArchiveHeader(
            withAAEncodedData: UnsafeBufferPointer(start: encoded, count: __AAHeaderGetEncodedSize(header)))
    }

    private func record(_ status: Int32) {
        if status < 0 { refused = true }
    }
}

/// The fields of an arriving entry its landing is decided by, each `nil` when
/// the header has no field of that key and type.
struct ClipboardArchiveEntryFields {
    /// `TYP`.
    var type: UInt64?
    /// `PAT`, raw bytes.
    var path: [UInt8]?

    /// The fields of `header`, or `nil` when its encoding does not parse.
    init?(_ header: ArchiveHeader) {
        guard
            let parsed = header.withAAEncodedData({ encoded -> __AAHeader? in
                guard let base = encoded.baseAddress else { return nil }
                return __AAHeaderCreateWithEncodedData(encoded.count, base)
            })
        else { return nil }
        defer { __AAHeaderDestroy(parsed) }

        func index(_ key: String) -> UInt32? {
            let found = __AAHeaderGetKeyIndex(parsed, fieldKey(key))
            return found >= 0 ? UInt32(found) : nil
        }
        if let field = index("TYP") {
            var value: UInt64 = 0
            if __AAHeaderGetFieldUInt(parsed, field, &value) >= 0 { type = value }
        }
        if let field = index("PAT") {
            var length = 0
            if __AAHeaderGetFieldString(parsed, field, 0, nil, &length) >= 0 {
                // The copy is NUL-terminated, so it needs one byte past the string.
                var bytes = [CChar](repeating: 0, count: length + 1)
                if __AAHeaderGetFieldString(parsed, field, bytes.count, &bytes, &length) >= 0 {
                    path = bytes[..<length].map { UInt8(bitPattern: $0) }
                }
            }
        }
    }
}
