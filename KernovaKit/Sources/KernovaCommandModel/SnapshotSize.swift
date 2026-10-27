import Foundation

/// What a snapshot's files take on its volume.
public struct SnapshotSize: Codable, Sendable, Hashable {
    /// Every byte allocated to the snapshot's files, shared or not.
    public let bytes: UInt64
    /// The bytes no clone or volume snapshot shares — the space freed once the
    /// snapshot is deleted and the Trash is emptied. `nil` on a volume that
    /// can't clone files, where `bytes` is that space, or when it can't be read.
    public let privateBytes: UInt64?

    /// A size of `bytes`, with `privateBytes` where the volume clones files.
    public init(bytes: UInt64, privateBytes: UInt64?) {
        self.bytes = bytes
        self.privateBytes = privateBytes
    }
}
