import CryptoKit
import Foundation

/// UUIDs fixed by a seed string, for entries that are re-derived rather than
/// persisted and still need identity that survives the re-derivation.
enum StableID {
    /// A UUID fixed by `seed`.
    static func uuid(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}
