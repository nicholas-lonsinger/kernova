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
/// `RATIONALE:` bit 63 is reserved for direction, so this assumes a generation
/// never reaches 2^47 (one per local copy — unreachable in practice).
///
/// `RATIONALE:` the id is **intentionally** reproducible from
/// `(generation, repIndex, direction)` alone — both `cancelStagedPull` sites
/// (`VsockClipboardService`, `VsockGuestClipboardAgent`) re-derive it from
/// those three values rather than remembering the id they minted, and
/// `FileProviderServiceSource.cancelPull`'s race-win guard depends on the same
/// `(generation, repIndex)` always yielding the same id. A per-attempt
/// discriminator (considered for #499, a stale cancel/abort racing a re-pull
/// of the identical offer) was deferred: it would break this determinism
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

    /// Mints a `transfer_id` from an offer generation and rep index, tagging the
    /// direction. `hostMinted` is `true` when the host is minting (it is the
    /// offer's receiver), `false` when the guest is.
    public static func make(generation: UInt64, repIndex: Int, hostMinted: Bool) -> UInt64 {
        let base = (generation << 16) | UInt64(repIndex)
        return hostMinted ? (base | hostReceivesBit) : base
    }

    /// Whether `transferID` is one the host receives (its direction bit is set).
    public static func hostReceives(_ transferID: UInt64) -> Bool {
        transferID & hostReceivesBit != 0
    }
}
