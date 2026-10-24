import Darwin
import Foundation

/// Which item a transfer failed on, and how: an item the sending side could not
/// read, or an entry the receiving side could not write.
///
/// Raised where the read or write happens, so the item is the one that actually
/// failed rather than one inferred afterwards; it crosses the wire as a
/// `ClipboardItemFailure`. Its descriptions leave the item out, so a log line
/// that interpolates one publicly names only the reason — the item is logged
/// apart, as private.
public struct ClipboardItemFailure: Error, Equatable, Sendable {
    /// How the read or write failed.
    public enum Reason: Equatable, Sendable {
        /// The read or write failed with this `errno`.
        case posix(Int32)
        /// The file ended before the size its archive entry declared; a read
        /// failure only.
        case endedEarly
        /// The failure named no reason.
        case unknown
    }

    /// The item, as a slash-separated path. On the wire and to the receiver it
    /// starts with the representation's own name; inside the archive codec it is
    /// relative to the source, empty for the source itself.
    public let itemPath: String
    /// How the read or write failed.
    public let reason: Reason

    /// The most a serialized failure may take in an abort trailer.
    static let maximumEncodedByteCount = 4096

    /// Creates a failure naming the item at `itemPath`.
    public init(itemPath: String, reason: Reason) {
        self.itemPath = itemPath
        self.reason = reason
    }

    /// The failed item's own name — the last component of ``itemPath`` — or
    /// empty when the path names nothing.
    public var itemName: String {
        itemPath.split(separator: "/").last.map(String.init) ?? ""
    }

    /// The same failure with its path placed under `name`, the representation's
    /// own name.
    func within(_ name: String) -> ClipboardItemFailure {
        guard !name.isEmpty else { return self }
        return ClipboardItemFailure(
            itemPath: itemPath.isEmpty ? name : "\(name)/\(itemPath)", reason: reason)
    }
}

extension ClipboardItemFailure.Reason {
    /// The reason `error` carries: its POSIX code where it has one.
    init(_ error: any Error) {
        if let posix = error as? POSIXError {
            self = .posix(posix.code.rawValue)
            return
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            self = .posix(Int32(ns.code))
        } else if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            self = .posix(Int32(underlying.code))
        } else {
            self = .unknown
        }
    }
}

extension ClipboardItemFailure: CustomStringConvertible, CustomDebugStringConvertible {
    /// The reason alone, with the item left out.
    public var description: String {
        switch reason {
        case .posix(let code): "\(String(cString: strerror(code))) (errno \(code))"
        case .endedEarly: "ended before its declared size"
        case .unknown: "no reason given"
        }
    }

    /// The reason alone, as ``description`` gives it.
    public var debugDescription: String { description }
}

// MARK: - Wire

extension ClipboardItemFailure {
    /// The failure as it crosses the wire.
    var wire: Kernova_V1_ClipboardItemFailure {
        .with {
            $0.itemPath = itemPath
            switch reason {
            case .posix(let code): $0.posixError = code
            case .endedEarly: $0.endedEarly = true
            case .unknown: break
            }
        }
    }

    /// The failure a peer sent.
    init(wire: Kernova_V1_ClipboardItemFailure) {
        let reason: Reason =
            wire.endedEarly ? .endedEarly : wire.posixError != 0 ? .posix(wire.posixError) : .unknown
        self.init(itemPath: wire.itemPath, reason: reason)
    }

    /// The serialized failure, within ``maximumEncodedByteCount``: a path too
    /// long to fit crosses as the item's own name.
    var encoded: Data {
        let full = (try? wire.serializedData()) ?? Data()
        guard full.count > Self.maximumEncodedByteCount else { return full }
        let short = ClipboardItemFailure(itemPath: itemName, reason: reason)
        let trimmed = (try? short.wire.serializedData()) ?? Data()
        return trimmed.count <= Self.maximumEncodedByteCount ? trimmed : Data()
    }

    /// The failure `bytes` serialize, or `nil` when they are not one.
    init?(encoded bytes: Data) {
        guard !bytes.isEmpty, let wire = try? Kernova_V1_ClipboardItemFailure(serializedBytes: bytes)
        else { return nil }
        self.init(wire: wire)
    }
}
