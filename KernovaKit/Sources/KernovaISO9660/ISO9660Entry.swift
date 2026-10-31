/// One file in the root directory of an image ``ISO9660Writer`` writes.
public struct ISO9660Entry: Sendable {
    /// Writes the next piece of a file's bytes.
    public typealias Sink = ([UInt8]) throws -> Void

    /// The name a Rock Ridge reader shows: any bytes but `/` and NUL, at most
    /// ``maximumNameLength`` of them in UTF-8, and neither `.` nor `..`.
    public var name: String
    /// The POSIX permission bits, at most `0o7777`.
    public var permissions: UInt16
    /// How many bytes ``contents`` writes.
    public var size: UInt64
    /// Writes the file's bytes, in order and in pieces of any size, to the sink it is handed. The writer
    /// calls it once, when the file's turn in the image comes, so the file is never held whole.
    public var contents: @Sendable (_ sink: Sink) throws -> Void

    /// The longest name, in UTF-8 bytes: the most a directory record holds beside its other entries.
    public static let maximumNameLength = 128

    /// A file named `name` with `permissions`, whose `size` bytes `contents` writes.
    public init(
        name: String, permissions: UInt16, size: UInt64, contents: @escaping @Sendable (_ sink: Sink) throws -> Void
    ) {
        self.name = name
        self.permissions = permissions
        self.size = size
        self.contents = contents
    }

    /// A file holding `bytes`.
    public init(name: String, permissions: UInt16, bytes: [UInt8]) {
        self.init(name: name, permissions: permissions, size: UInt64(bytes.count)) { sink in try sink(bytes) }
    }
}

/// A moment an image records, in UTC.
public struct ISO9660Date: Sendable, Equatable {
    /// The year, 1900 to 2155.
    public var year: Int
    /// The month, 1 to 12.
    public var month: Int
    /// The day of the month, from 1.
    public var day: Int
    /// The hour, 0 to 23.
    public var hour: Int
    /// The minute, 0 to 59.
    public var minute: Int
    /// The second, 0 to 59.
    public var second: Int

    /// The moment `year`-`month`-`day` `hour`:`minute`:`second` UTC; `year` from 1900 to 2155.
    public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }
}

/// Why ``ISO9660Writer`` refused to write an image.
public enum ISO9660Error: Error, Sendable, Equatable {
    /// The volume identifier is empty, longer than 32 characters, or holds a character other than `A`–`Z`,
    /// `0`–`9` and `_`.
    case invalidVolumeIdentifier(String)
    /// The date is outside 1900–2155 or names no real moment.
    case invalidDate(ISO9660Date)
    /// The name is empty, `.`, `..`, too long, or holds `/` or NUL.
    case invalidName(String)
    /// The permissions have bits beyond `0o7777`.
    case invalidPermissions(name: String, permissions: UInt16)
    /// Two entries have this name.
    case duplicateName(String)
    /// The file is 4 GiB or larger, which one extent cannot hold.
    case fileTooLarge(name: String, size: UInt64)
    /// The image would outgrow the 32-bit block numbers ECMA-119 addresses it with.
    case imageTooLarge
    /// `contents` wrote a different number of bytes than `size` said.
    case sizeMismatch(name: String, declared: UInt64, written: UInt64)
}
