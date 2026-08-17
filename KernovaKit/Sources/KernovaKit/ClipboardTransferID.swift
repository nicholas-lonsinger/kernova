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
/// `RATIONALE (2026-08-16):` the id is **intentionally** reproducible from
/// `(generation, repIndex, direction)` alone — a re-fire for the same rep, or the
/// window's preview fetch of it, must land on the same id so it *joins* the
/// `LazyPullCoordinator`'s in-flight pull rather than opening a second one. A
/// reused id's worst case is one spurious re-abort, never corruption — pinned by
/// `LazyPullCoordinatorTests.staleAbortCollidesWithReusedAwaiterButTableStaysConsistent`.
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

    /// The offer generation encoded in `transferID`, ignoring the direction bit —
    /// so supersession cancel matches transfers in either direction.
    public static func generation(of transferID: UInt64) -> UInt64 {
        (transferID & ~hostReceivesBit) >> 16
    }

    /// The representation index encoded in `transferID`, which a peer's request
    /// carries and the offer holder resolves against its own representation list.
    public static func repIndex(of transferID: UInt64) -> Int {
        Int(transferID & 0xFFFF)
    }
}
