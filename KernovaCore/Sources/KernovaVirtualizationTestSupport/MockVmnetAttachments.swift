import Foundation
import Synchronization
import Virtualization

@testable import KernovaCore
@testable import KernovaVirtualization

/// Scripted stand-in for `VmnetAttachmentMaking`: a NAT attachment for every
/// handle, since the vmnet one would retain a scripted operator's fabricated
/// pointer as a real network.
final class MockVmnetAttachments: VmnetAttachmentMaking {
    private let made = Mutex<[ObjectIdentifier]>([])

    /// The identity of every attachment built, in call order.
    var madeIdentities: [ObjectIdentifier] { made.withLock { $0 } }

    func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment {
        let attachment = VZNATNetworkDeviceAttachment()
        made.withLock { $0.append(ObjectIdentifier(attachment)) }
        return attachment
    }
}
