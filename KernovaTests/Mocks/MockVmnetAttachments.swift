import Foundation
import Virtualization

@testable import Kernova
@testable import KernovaCore

/// Scripted stand-in for `VmnetAttachmentMaking`: a NAT attachment for every
/// handle, since the vmnet one would retain a scripted operator's fabricated
/// pointer as a real network.
final class MockVmnetAttachments: VmnetAttachmentMaking, @unchecked Sendable {
    /// Every attachment built, in call order.
    private(set) var made: [VZNetworkDeviceAttachment] = []

    func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment {
        let attachment = VZNATNetworkDeviceAttachment()
        made.append(attachment)
        return attachment
    }
}
