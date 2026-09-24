import Foundation
@testable import Kernova

extension VMSnapshot {
    /// A snapshot built field by field, for a test that seeds a manifest.
    ///
    /// `macAddress` has no default, as in production: it is the address the
    /// snapshot keeps reserved, and a test that means "none" says so.
    init(
        id: UUID = UUID(), name: String, createdAt: Date = Date(), notes: String = "",
        kind: VMSnapshotKind = .warm, macAddress: String?
    ) {
        self.init(
            VMSnapshotRecord(id: id, name: name, createdAt: createdAt, notes: notes, kind: kind),
            macAddress: macAddress)
    }
}
