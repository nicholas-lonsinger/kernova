import Foundation
import KernovaCore
import KernovaKit
import KernovaLogging
import Virtualization
import vmnet

/// Builds the Virtualization attachment that joins a materialized vmnet
/// network.
package struct VmnetAttachmentMaker: Sendable {
    private let makeAttachment: @Sendable (OpaquePointer) -> VZNetworkDeviceAttachment

    /// A maker building each attachment over a network object with
    /// `makeAttachment` — tests pass one that needs no real vmnet network.
    package init(_ makeAttachment: @escaping @Sendable (OpaquePointer) -> VZNetworkDeviceAttachment) {
        self.makeAttachment = makeAttachment
    }

    /// The maker over the real `VZVmnetNetworkDeviceAttachment`.
    package static let host = VmnetAttachmentMaker { VZVmnetNetworkDeviceAttachment(network: $0) }

    /// A VZ attachment joining `handle`'s network, which holds `handle` until
    /// it deallocates — `VZVmnetNetworkDeviceAttachment.h` declares `network`
    /// with no ownership (`@property (readonly) vmnet_network_ref network;`).
    package func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment {
        let attachment = makeAttachment(handle.network)
        // The handle's own address is unique while the association holds it,
        // and a stored global key would need an unchecked concurrency escape.
        objc_setAssociatedObject(
            attachment, Unmanaged.passUnretained(handle).toOpaque(), handle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return attachment
    }
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

/// The real `VmnetNetworkOperating`, over the macOS 26 vmnet network APIs.
package struct HostVmnetNetworkOperator: VmnetNetworkOperating {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HostVmnetNetworkOperator")

    package init() {}

    package func createNetwork(_ kind: VmnetNetworkKind) throws -> (
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
        let handle = VmnetNetworkHandle(adopting: network)

        var address = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(handle.network, &address, &mask)
        let subnet = IPv4Subnet(
            containing: UInt32(bigEndian: address.s_addr), mask: UInt32(bigEndian: mask.s_addr))
        Self.logger.log(
            .notice,
            "Created a \(kind.rawValue, privacy: .public) network on \(IPv4Value.string(subnet.network), privacy: .public) mask \(IPv4Value.string(subnet.mask), privacy: .public)"
        )
        return (handle, subnet)
    }

    private func mode(for kind: VmnetNetworkKind) -> operating_modes_t {
        switch kind {
        case .hostOnly: .VMNET_HOST_MODE
        case .nat: .VMNET_SHARED_MODE
        }
    }
}
