import Foundation

/// The bounds a receiver puts on a peer's declared clipboard metadata before any
/// of it reaches budget, capacity, or progress arithmetic.
///
/// An offer's `byte_count` and a stream Begin's `total_bytes` are peer-supplied
/// and never cross-checked against the bytes that follow, so all a declared size
/// does is fail a cap or a free-space check honestly. Bounding them once at
/// intake is what keeps every later sum finite and every capacity check in
/// range.
public enum ClipboardOfferBounds {
    /// Ceiling on any peer-declared byte count: 64 TiB.
    ///
    /// Above any payload a clipboard can carry, and low enough that a full
    /// offer's worth of them (`ClipboardContent.maxOfferableRepresentations`)
    /// still sums well inside `Int64`. A clamped size is still far past the
    /// deadline-safe paste cap and any real volume's free space, so clamping
    /// changes which checks fail only by making them fail arithmetically.
    public static let maxDeclaredByteCount: UInt64 = 1 << 46

    /// `reps` bounded to what the receive side is willing to reason about: at
    /// most `ClipboardContent.maxOfferableRepresentations` representations — the
    /// bound a sender imposes on itself, and the most a 16-bit transfer-id rep
    /// index can address — each declared `byte_count` clamped to
    /// `maxDeclaredByteCount`.
    ///
    /// Truncation drops from the tail, so every surviving rep keeps the index
    /// the wire gave it. `truncatedFrom` is the original count when truncation
    /// happened and `nil` otherwise; `clampedCount` is how many byte counts were
    /// clamped — both for the caller to log.
    public static func bounded(
        _ reps: [Kernova_V1_ClipboardRepresentationInfo]
    ) -> (reps: [Kernova_V1_ClipboardRepresentationInfo], truncatedFrom: Int?, clampedCount: Int) {
        let originalCount = reps.count
        let truncated = originalCount > ClipboardContent.maxOfferableRepresentations
        var bounded =
            truncated ? Array(reps.prefix(ClipboardContent.maxOfferableRepresentations)) : reps
        var clampedCount = 0
        for index in bounded.indices where bounded[index].byteCount > maxDeclaredByteCount {
            bounded[index].byteCount = maxDeclaredByteCount
            clampedCount += 1
        }
        return (bounded, truncated ? originalCount : nil, clampedCount)
    }
}
