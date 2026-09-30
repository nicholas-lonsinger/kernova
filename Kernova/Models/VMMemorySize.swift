import Foundation

/// A guest memory size: a whole number of mebibytes, the granularity
/// `VZVirtualMachineConfiguration.memorySize` requires.
///
/// Persisted as a number of gibibytes — an integer when the size is whole, a
/// decimal otherwise — and decoded from either, rounded to the nearest
/// mebibyte.
struct VMMemorySize: Hashable, Comparable, Sendable, Codable {
    /// 32 bits, so ``bytes`` cannot overflow.
    let mebibytes: UInt32

    init(mebibytes: UInt32) {
        self.mebibytes = mebibytes
    }

    /// A whole number of gibibytes, saturating at the largest size.
    static func gibibytes(_ gibibytes: UInt32) -> VMMemorySize {
        VMMemorySize(mebibytes: UInt32(clamping: UInt64(gibibytes) * UInt64(mebibytesPerGibibyte)))
    }

    /// `gibibytes` rounded to the nearest mebibyte, or `nil` when that is not
    /// a size.
    init?(gibibytes: Double) {
        let mebibytes = (gibibytes * Double(Self.mebibytesPerGibibyte)).rounded()
        guard let exact = UInt32(exactly: mebibytes) else { return nil }
        self.mebibytes = exact
    }

    /// The size a decimal count of gibibytes names, written with a `.`
    /// separator, rounded to the nearest mebibyte.
    init?(gibibytesText text: String) {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            value.isFinite
        else { return nil }
        self.init(gibibytes: value)
    }

    /// The largest size at or below `bytes`.
    init(roundingDown bytes: UInt64) {
        mebibytes = UInt32(clamping: bytes / Self.bytesPerMebibyte)
    }

    /// The smallest size at or above `bytes`.
    init(roundingUp bytes: UInt64) {
        let (whole, remainder) = bytes.quotientAndRemainder(dividingBy: Self.bytesPerMebibyte)
        mebibytes = UInt32(clamping: remainder == 0 ? whole : whole + 1)
    }

    var bytes: UInt64 {
        UInt64(mebibytes) * Self.bytesPerMebibyte
    }

    var gibibytes: Double {
        Double(mebibytes) / Double(Self.mebibytesPerGibibyte)
    }

    /// The size in gibibytes as ``init(gibibytesText:)`` reads it back: no
    /// decimals for a whole size, otherwise the fewest that name this size.
    var gibibytesText: String {
        let (whole, remainder) = mebibytes.quotientAndRemainder(dividingBy: Self.mebibytesPerGibibyte)
        guard remainder != 0 else { return String(whole) }
        // Four decimals resolve a tenth of a mebibyte, so the loop always returns.
        for decimals in 1...4 {
            let text = String(format: "%.\(decimals)f", gibibytes)
            if VMMemorySize(gibibytesText: text) == self { return text }
        }
        return String(gibibytes)
    }

    /// The whole gibibyte a stepper arrow moves to: the next one above this
    /// size when `upward`, else the next one below it.
    func nextWholeGibibyte(upward: Bool) -> VMMemorySize {
        let (whole, remainder) = mebibytes.quotientAndRemainder(dividingBy: Self.mebibytesPerGibibyte)
        let target: UInt32
        if upward {
            target = whole + 1
        } else {
            target = remainder == 0 ? (whole == 0 ? 0 : whole - 1) : whole
        }
        return VMMemorySize(mebibytes: UInt32(clamping: UInt64(target) * UInt64(Self.mebibytesPerGibibyte)))
    }

    static func < (lhs: VMMemorySize, rhs: VMMemorySize) -> Bool {
        lhs.mebibytes < rhs.mebibytes
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let gibibytes = try container.decode(Double.self)
        guard gibibytes.isFinite, let size = VMMemorySize(gibibytes: gibibytes) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\(gibibytes) GiB is not a memory size")
        }
        self = size
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let (whole, remainder) = mebibytes.quotientAndRemainder(dividingBy: Self.mebibytesPerGibibyte)
        if remainder == 0 {
            try container.encode(whole)
        } else {
            try container.encode(gibibytes)
        }
    }

    private static let bytesPerMebibyte: UInt64 = 1 << 20
    private static let mebibytesPerGibibyte: UInt32 = 1024
}
