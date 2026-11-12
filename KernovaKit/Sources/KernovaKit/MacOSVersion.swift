import Foundation

/// A macOS release number, written the way Apple names a release.
///
/// The text form is one to three dot-separated decimal components with a zero
/// patch left off: `26.6.0` reads `"26.6"`, `12.0.1` reads `"12.0.1"`. Order is
/// numeric, so 12.10 is newer than 12.3, and a missing component is zero, so
/// `"26.0"` equals `"26.0.0"`.
public struct MacOSVersion: Sendable, Hashable, Comparable, LosslessStringConvertible {
    /// The first component: 26 in 26.6.1.
    public let major: Int
    /// The second component: 6 in 26.6.1.
    public let minor: Int
    /// The third component: 1 in 26.6.1, 0 for a release with none.
    public let patch: Int

    /// The version `major.minor.patch`.
    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The version `version` decomposes.
    public init(_ version: OperatingSystemVersion) {
        self.init(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    /// `nil` unless `description` is one to three dot-separated runs of ASCII
    /// digits, each fitting an `Int`.
    public init?(_ description: String) {
        let parts = description.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// The version as Apple names the release, a zero patch left off.
    public var description: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// Whether `lhs` is the older release.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
