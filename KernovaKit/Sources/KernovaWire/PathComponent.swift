/// The protocol's one rule for a name that lands on a file system: an offered FILE or FOLDER item's
/// `Representation.name`, and every container entry's name below the root.
public enum PathComponent {
    /// The longest name a POSIX file system takes, `NAME_MAX`.
    public static let maxByteCount = 255

    /// Whether `name` is one path component a POSIX file system takes as it is: non-empty, at most
    /// ``maxByteCount`` bytes, neither `.` nor `..`, and holding no `/` or NUL.
    public static func isValid(_ name: some Collection<UInt8>) -> Bool {
        guard !name.isEmpty, name.count <= maxByteCount else { return false }
        guard !name.elementsEqual([0x2E]), !name.elementsEqual([0x2E, 0x2E]) else { return false }
        return !name.contains(0x2F) && !name.contains(0)
    }
}
