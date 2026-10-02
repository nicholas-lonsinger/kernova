import Foundation
@testable import Kernova

extension VMSnapshot {
    /// A snapshot built field by field, for a test that seeds a manifest.
    ///
    /// `macAddress` has no default, as in production: it is the address the
    /// snapshot keeps reserved, and a test that means "none" says so. The rest
    /// of the captured network device is a Shared Network one on its common
    /// network unless `network` names another, which then carries the address
    /// too.
    init(
        id: UUID = UUID(), name: String, createdAt: Date = Date(), notes: String = "",
        kind: VMSnapshotKind = .warm, macAddress: String?, network: VMCapturedNetwork? = nil
    ) {
        self.init(
            VMSnapshotRecord(id: id, name: name, createdAt: createdAt, notes: notes, kind: kind),
            network: network
                ?? VMCapturedNetwork(
                    networkEnabled: true, networkMode: .shared, networkMembership: .common,
                    bridgedInterfaceIdentifier: nil, macAddress: macAddress))
    }
}
