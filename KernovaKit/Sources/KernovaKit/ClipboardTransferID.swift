import Foundation

/// Derives and inspects clipboard `transfer_id`s.
///
/// A `transfer_id` is `(generation << 16) | repIndex` plus a high **direction
/// bit**, set by the host on every id it mints and never by the guest — so a set
/// bit means "the host receives" (guest→host) and a clear bit "the guest
/// receives". Both peers seed their offer generations independently from 1, so
/// without the tag the two directions collide at the same generation, sharing one
/// key across a peer's sender *and* receiver tables where a single
/// `ClipboardStreamAbort` would tear down both.
///
/// ## Child transfers (folder placeholder tree, `clipboard.dirtree.v1`)
/// The 16-bit rep index cannot address a child *within* a directory rep, so a
/// second high bit selects a distinct **child layout** keyed by
/// `(generation, repIndex, childSeq)`:
///
/// ```
///  bit 63        : direction   (host receives)
///  bit 62        : child transfer flag (1 = child/tree, 0 = legacy rep)
///  bits 38..61   : generation  (24 bits)
///  bits 22..37   : rep index   (16 bits)
///  bits  0..21   : child seq   (22 bits) — 0 = the directory's tree listing,
///                               >= 1 = a tree node (file) within the rep
/// ```
///
/// `childSeq` is the producer-assigned 1-based node sequence from its tree walk;
/// 0 is reserved for the listing itself, whose folder-root node never carries
/// bytes. Both layouts cap what they can encode — a generation of 2^46 for the
/// legacy layout, 2^24 offers or ~4M tree nodes for the child layout.
///
/// `RATIONALE:` (verified 2026-07-27) the id is **intentionally** reproducible
/// from `(generation, repIndex, direction)` alone — plus `childSeq` for a child
/// transfer. Both `cancelStagedPull` sites re-derive it rather than remembering
/// what they minted, and `FileProviderServiceSource.cancelPull`'s race-win guard
/// needs the same key to always yield the same id. A per-attempt discriminator
/// (#499) would break that everywhere, to close a window whose worst case is one
/// spurious re-abort, never corruption — covered by
/// `LazyPullCoordinatorTests.staleAbortCollidesWithReusedAwaiterButTableStaysConsistent`.
public enum ClipboardTransferID {
    /// High bit marking a transfer the **host** receives (guest→host direction).
    public static let hostReceivesBit: UInt64 = 1 << 63

    /// Bit marking a **child/tree** transfer (folder placeholder tree), which
    /// uses the child layout instead of `(generation << 16) | repIndex`.
    public static let childTransferBit: UInt64 = 1 << 62

    private static let childSeqMask: UInt64 = 0x3F_FFFF  // 22 bits
    private static let childRepShift: UInt64 = 22
    private static let childRepMask: UInt64 = 0xFFFF  // 16 bits
    private static let childGenerationShift: UInt64 = 38
    private static let childGenerationMask: UInt64 = 0xFF_FFFF  // 24 bits

    /// Mints a `transfer_id` from an offer generation and rep index, tagging the
    /// direction. `hostMinted` is `true` when the host is minting (it is the
    /// offer's receiver), `false` when the guest is.
    public static func make(generation: UInt64, repIndex: Int, hostMinted: Bool) -> UInt64 {
        let base = (generation << 16) | UInt64(repIndex)
        return hostMinted ? (base | hostReceivesBit) : base
    }

    /// Mints a **child** `transfer_id` for a directory rep's tree listing
    /// (`childSeq == 0`) or one of its tree nodes (`childSeq >= 1`), tagging the
    /// direction.
    ///
    /// Deterministic per `(generation, repIndex, childSeq, direction)` so cancels
    /// re-derive it (see the type doc).
    public static func makeChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, hostMinted: Bool
    ) -> UInt64 {
        let g = (generation & childGenerationMask) << childGenerationShift
        let r = (UInt64(repIndex) & childRepMask) << childRepShift
        let c = UInt64(childSeq) & childSeqMask
        let base = childTransferBit | g | r | c
        return hostMinted ? (base | hostReceivesBit) : base
    }

    /// Whether `transferID` is one the host receives (its direction bit is set).
    public static func hostReceives(_ transferID: UInt64) -> Bool {
        transferID & hostReceivesBit != 0
    }

    /// Whether `transferID` uses the child (folder-tree) layout.
    public static func isChild(_ transferID: UInt64) -> Bool {
        transferID & childTransferBit != 0
    }

    /// The offer generation encoded in `transferID`, ignoring the direction bit
    /// and honoring both layouts — so supersession cancel matches child and
    /// legacy transfers alike.
    public static func generation(of transferID: UInt64) -> UInt64 {
        let bits = transferID & ~hostReceivesBit
        if bits & childTransferBit != 0 {
            return (bits >> childGenerationShift) & childGenerationMask
        }
        return bits >> 16
    }

    /// The child sequence encoded in a child-layout `transferID` (0 for the
    /// listing).
    ///
    /// Undefined for a legacy id — callers gate on `isChild`.
    public static func childSeq(of transferID: UInt64) -> UInt32 {
        UInt32(transferID & childSeqMask)
    }
}
