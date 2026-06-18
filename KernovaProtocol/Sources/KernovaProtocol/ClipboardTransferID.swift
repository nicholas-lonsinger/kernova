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
