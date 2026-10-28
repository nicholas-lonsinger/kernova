import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaWire

/// One VM's update payloads as its agent hub offers and serves them: the bundled agents for its guest OS.
struct BundledGuestAgentPayloads: BundledPayloadProvider {
    let agents: BundledGuestAgents
    let os: OSFamily

    /// The payloads `agents` bundles for a VM of `guestOS`.
    init(_ agents: BundledGuestAgents, guestOS: VMGuestOS) {
        self.agents = agents
        self.os =
            switch guestOS {
            case .macOS: .macOS
            case .linux: .linux
            }
    }

    /// Answers ``BundledGuestAgents/payloads(for:)`` for the VM's OS, off the caller's thread.
    func loadPayloads(_ completion: @escaping @Sendable ([BundledPayload]) -> Void) {
        let agents = agents
        let os = os
        Task.detached(priority: .utility) { completion(await agents.payloads(for: os)) }
    }

    /// Reads up to `count` bytes at `offset` of the bundled file `manifest` was made from, with a
    /// positional read, off the caller's thread.
    func read(
        manifest: UpdateManifestValue, offset: UInt64, count: Int,
        _ completion: @escaping @Sendable (Result<Data, WireError>) -> Void
    ) {
        let agents = agents
        let os = os
        Task.detached(priority: .utility) {
            guard let url = await agents.payloadFile(for: manifest, os: os) else {
                return completion(.failure(WireError(.readFailed, debugDetail: "no bundled payload has this hash")))
            }
            completion(Self.read(url, offset: offset, count: count))
        }
    }

    /// `pread(2)` of `count` bytes at `offset` in the file at `url`: fewer at the end of the file, and none
    /// past it.
    static func read(_ url: URL, offset: UInt64, count: Int) -> Result<Data, WireError> {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .failure(WireError(.readFailed, debugDetail: "open failed: errno \(errno)"))
        }
        defer { close(descriptor) }
        var bytes = Data(count: count)
        var received = -1
        repeat {
            received = bytes.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
            }
        } while received < 0 && errno == EINTR
        guard received >= 0 else {
            return .failure(WireError(.readFailed, debugDetail: "pread failed: errno \(errno)"))
        }
        bytes.count = received
        return .success(bytes)
    }
}
