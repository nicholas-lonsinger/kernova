import Foundation
import Synchronization
import Virtualization

@testable import KernovaCore
@testable import KernovaVirtualization

/// Records what its ``maker`` builds: a NAT attachment for every network, since
/// the vmnet one needs a real vmnet network.
final class MockVmnetAttachments: Sendable {
    private struct Made {
        var identities: [ObjectIdentifier] = []
        var networks: [UInt] = []
    }

    private let made = Mutex(Made())

    /// The identity of every attachment built, in call order.
    var madeIdentities: [ObjectIdentifier] { made.withLock { $0.identities } }

    /// The network each attachment was built over, in call order.
    var madeNetworks: [OpaquePointer] {
        made.withLock { $0.networks }.compactMap { OpaquePointer(bitPattern: $0) }
    }

    var maker: VmnetAttachmentMaker {
        VmnetAttachmentMaker { network in
            let attachment = VZNATNetworkDeviceAttachment()
            let address = UInt(bitPattern: network)
            self.made.withLock {
                $0.identities.append(ObjectIdentifier(attachment))
                $0.networks.append(address)
            }
            return attachment
        }
    }
}
