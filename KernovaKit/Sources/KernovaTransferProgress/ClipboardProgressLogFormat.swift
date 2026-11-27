#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// How a log record spells a transfer's readout — never shown to a user, who
/// gets `ClipboardProgressFormat` instead.
package enum ClipboardProgressLogFormat {
    /// Seconds to two decimal places ("2.00 s"), or `unknown` where there is no
    /// estimate.
    package static func logSeconds(_ value: TimeInterval?) -> String {
        guard let value else { return "unknown" }
        guard let hundredths = Int64(exactly: (value * 100).rounded()) else { return "\(value) s" }
        let fraction = hundredths.magnitude % 100
        return "\(hundredths < 0 ? "-" : "")\(hundredths.magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction) s"
    }

    /// Bytes as a log record spells them ("512/4096 bytes"), or `size unknown`
    /// for an operation that does not know its bytes.
    package static func logBytes(transferred: UInt64, total: UInt64, known: Bool) -> String {
        known ? "\(transferred)/\(total) bytes" : "size unknown"
    }
}
