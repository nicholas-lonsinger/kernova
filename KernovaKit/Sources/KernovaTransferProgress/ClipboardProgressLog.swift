#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// How a log record spells a transfer's figures — never shown to a user, who reads `ClipboardProgressFormat`'s.
package enum ClipboardProgressLog {
    /// Seconds to two places ("2.00 s"), or `unknown` where there is no estimate.
    package static func seconds(_ value: TimeInterval?) -> String {
        guard let value else { return "unknown" }
        let hundredths = (abs(value) * 100).rounded()
        guard hundredths < 1e15 else { return "\(value) s" }
        let whole = Int64(hundredths)
        let sign = value < 0 && whole > 0 ? "-" : ""
        let fraction = whole % 100
        return "\(sign)\(whole / 100).\(fraction < 10 ? "0" : "")\(fraction) s"
    }

    /// Bytes ("512/4096 bytes"), or `size unknown` for an operation that does not know its bytes.
    package static func bytes(transferred: UInt64, total: UInt64, known: Bool) -> String {
        known ? "\(transferred)/\(total) bytes" : "size unknown"
    }
}
