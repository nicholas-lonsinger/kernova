import Foundation

/// Why a user-supplied restore image URL was refused.
enum RestoreImageProbeError: LocalizedError, Equatable {
    case insecureURL
    case unreachable(statusCode: Int)
    case unknownSize
    case rangeRequestsUnsupported
    case notAVirtualMachineImage
    case unreadableStructure
    case transportFailed(description: String)

    var errorDescription: String? {
        switch self {
        case .insecureURL:
            "That link isn't secure. Restore images must be served over HTTPS."
        case .unreachable(let statusCode):
            "Nothing is hosted at that URL (HTTP \(statusCode)). Check the link and try again."
        case .unknownSize:
            "That server didn't report the file's size, so the image can't be checked before downloading."
        case .rangeRequestsUnsupported:
            """
            That server only sends whole files, so the image can't be checked before downloading. \
            Download it and add it with Choose Local File.
            """
        case .notAVirtualMachineImage:
            "This image can't run as a virtual machine. It has no VM hardware model."
        case .unreadableStructure:
            "That file isn't a readable restore image."
        case .transportFailed(let description):
            "Couldn't reach that URL: \(description)"
        }
    }
}

extension RestoreImageProbeError {
    /// States a size read that did not complete in restore-image terms.
    init(_ error: RemoteFileSizeError) {
        switch error {
        case .insecureURL: self = .insecureURL
        case .unreachable(let statusCode): self = .unreachable(statusCode: statusCode)
        case .unknownSize: self = .unknownSize
        case .rangeRequestsUnsupported: self = .rangeRequestsUnsupported
        case .transportFailed(let description): self = .transportFailed(description: description)
        }
    }
}

/// Abstraction for checking a user-supplied restore image URL before download.
protocol RestoreImageProbing: Sendable {
    /// Establishes that `url` serves an image that can install into a VM, and
    /// how large it is, without downloading it.
    func probe(_ url: URL) async throws -> ProbedRestoreImage

    /// How large the file at `url` is, without downloading it or reading its
    /// structure.
    ///
    /// Holds the URL guarantees ``probe(_:)`` rests on, so both entry points
    /// enforce them. A scheme other than `https` is refused with
    /// ``RestoreImageProbeError/insecureURL`` before any request is issued, and a
    /// server stating a length of zero with
    /// ``RestoreImageProbeError/unknownSize`` — a returned size is always
    /// greater than zero.
    func size(of url: URL) async throws -> UInt64
}
