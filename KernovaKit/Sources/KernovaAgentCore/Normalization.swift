#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The receiver's bounds on text and bytes Kernova does not own.
enum Normalize {
    /// Identity and state strings: at most this many UTF-8 bytes.
    static let identityStringBytes = 64
    /// `debug_detail` strings: at most this many UTF-8 bytes.
    static let debugDetailBytes = 1024
    /// `payload_hash` and `session_token`: at most this many bytes.
    static let hashBytes = 32
    /// `instance_id`: exactly this many bytes, or it reads as empty.
    static let instanceIDBytes = 16

    /// `text` without general categories Cc and Cf, clipped to `maxBytes` UTF-8
    /// bytes on a scalar boundary.
    static func display(_ text: String, maxBytes: Int) -> String {
        clip(stripped(text), maxBytes: maxBytes)
    }

    /// `text` without general categories Cc and Cf.
    static func stripped(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// `text` clipped to `maxBytes` UTF-8 bytes on a scalar boundary.
    static func clip(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var scalars = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            guard used + width <= maxBytes else { break }
            used += width
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// `bytes` clipped to at most `maxBytes`, as a copy of its own.
    static func clip(_ bytes: Data, maxBytes: Int) -> Data {
        bytes.count > maxBytes ? Data(bytes.prefix(maxBytes)) : bytes
    }
}
