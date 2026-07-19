import Foundation

/// Derives and inspects clipboard `transfer_id`s.
///
/// A `transfer_id` is `(generation << 16) | repIndex` plus a high **direction
/// bit**. Both peers seed their offer generations independently from 1, and the
/// *offer receiver* mints the id when it sends its `ClipboardRequest` — so
/// without a direction tag a host→guest transfer and a guest→host transfer at
/// the same generation collide (both `(1 << 16) | 0`). They would then occupy
/// the same key in one peer's sender *and* receiver tables, and a single
/// `ClipboardStreamAbort` would tear down both directions.
///
/// The host sets the direction bit on every id it mints (it is always the
/// *receiver* when it mints, replying to a guest offer); the guest never sets
/// it. So a set bit means "the host receives this transfer" (guest→host), a
/// clear bit means "the guest receives" (host→guest). With the bit, the host's
/// receiver-table ids and sender-table ids occupy disjoint keyspaces (and
/// likewise on the guest), and an abort routes to exactly one engine.
///
/// The low 16 bits stay the rep index and the next bits stay the generation, so
/// existing `transfer_id & 0xFFFF` rep-index extraction is unaffected.
/// `RATIONALE:` bit 63 is reserved for direction and bit 62 for the
/// child-transfer discriminator (below), so the legacy layout assumes a
/// generation never reaches 2^46 (one per local copy — unreachable in practice).
///
/// ## Child transfers (folder placeholder tree, `clipboard.dirtree.v1`)
/// A directory rep's placeholder tree fetches its listing and each child file
/// over the same stream transport, but the 16-bit rep index cannot address a
/// child *within* a directory rep. A second high bit (bit 62) selects a distinct
/// **child layout** for those transfers, keyed by `(generation, repIndex,
/// childSeq)`:
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
/// `childSeq` is the producer-assigned 1-based node sequence from its tree walk
/// (0 reserved for the listing itself, whose folder-root node never carries
/// bytes). The child layout preserves the direction bit and the determinism
/// invariant below; `RATIONALE:` its 24-bit generation and 22-bit child seq
/// assume a session never mints 2^24 offers or a tree past ~4M nodes — both
/// unreachable in practice (a per-local-copy counter; the design target is a
/// 100k-entry tree).
///
/// `RATIONALE:` the id is **intentionally** reproducible from
/// `(generation, repIndex, direction)` — plus `childSeq` for child transfers —
/// alone: both `cancelStagedPull` sites (`VsockClipboardService`,
/// `VsockGuestClipboardAgent`) re-derive it from those values rather than
/// remembering the id they minted, and `FileProviderServiceSource.cancelPull`'s
/// race-win guard depends on the same key always yielding the same id. A
/// per-attempt discriminator (considered for #499, a stale cancel/abort racing a
/// re-pull of the identical offer) was deferred: it would break this determinism
/// invariant everywhere it's relied on, to close a window normal Finder/File
/// Provider behavior doesn't produce and that is already bounded-benign — a
/// local stale cancel is caught by `cancelPull`'s one-shot race guard (shared
/// by host and guest), and a straggler wire `ClipboardStreamAbort` for a
/// since-reused id is caught by the sender/receiver `[L4]` dedup guards plus
/// the End-time SHA-256 verify (worst case: one spurious re-abort/retry, never
/// corruption — see `LazyPullCoordinatorTests.staleAbortCollidesWithReusedAwaiterButTableStaysConsistent`
/// for the regression coverage). If this window ever must be closed for real, the
/// mechanism is a capability-gated `epoch` field on `ClipboardStreamBegin` /
/// `ClipboardStreamAbort` (guest-agent version bump) — not an id-format
/// change, which would ripple through every re-derivation site above.
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
    /// Deterministic per `(generation, repIndex, childSeq, direction)`
    /// so cancels re-derive it (see the type doc).
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
