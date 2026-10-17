import Foundation
import KernovaCore
import KernovaKit
import KernovaLogging
import Virtualization
import vmnet

/// Builds the Virtualization attachment that joins a materialized vmnet
/// network, abstracted so tests build one without a real vmnet network — the
/// real attachment retains the network as a vmnet object.
protocol VmnetAttachmentMaking: Sendable {
    /// A VZ attachment joining `handle`'s network.
    func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment
}

/// Releases a vmnet object Swift imports as a bare `OpaquePointer`. The vmnet
/// header documents these as `CFRelease()`-able; Swift refuses a direct
/// `CFRelease` on an unmanaged import, so route through `Unmanaged`.
func releaseVmnetRef(_ ref: OpaquePointer) {
    Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ref)).release()
}

/// A vmnet call that failed.
struct VmnetOperationError: Error, LocalizedError {
    let operation: String
    let status: vmnet_return_t?

    var errorDescription: String? {
        if let status {
            "\(operation) failed (vmnet status \(status.rawValue))"
        } else {
            "\(operation) failed"
        }
    }
}

/// The real `VmnetNetworkOperating` and `VmnetAttachmentMaking`, over the
/// macOS 26 vmnet network APIs.
struct HostVmnetNetworkOperator: VmnetNetworkOperating, VmnetAttachmentMaking {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HostVmnetNetworkOperator")

    func createNetwork(_ kind: VmnetNetworkKind) throws -> (
        handle: VmnetNetworkHandle, subnet: IPv4Subnet
    ) {
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let configuration = vmnet_network_configuration_create(mode(for: kind), &status) else {
            throw VmnetOperationError(operation: "vmnet_network_configuration_create", status: status)
        }
        defer { releaseVmnetRef(configuration) }
        guard let network = vmnet_network_create(configuration, &status) else {
            throw VmnetOperationError(operation: "vmnet_network_create", status: status)
        }

        var address = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(network, &address, &mask)
        let subnet = IPv4Subnet(
            containing: UInt32(bigEndian: address.s_addr), mask: UInt32(bigEndian: mask.s_addr))
        #log(
            Self.logger, .notice,
            "Created a \(kind.rawValue, privacy: .public) network on \(IPv4Value.string(subnet.network), privacy: .public) mask \(IPv4Value.string(subnet.mask), privacy: .public)"
        )
        return (VmnetNetworkHandle(network: network), subnet)
    }

    func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment {
        VZVmnetNetworkDeviceAttachment(network: handle.network)
    }

    func releaseNetwork(_ handle: VmnetNetworkHandle) {
        releaseVmnetRef(handle.network)
    }

    private func mode(for kind: VmnetNetworkKind) -> operating_modes_t {
        switch kind {
        case .hostOnly: .VMNET_HOST_MODE
        case .nat: .VMNET_SHARED_MODE
        }
    }
}
