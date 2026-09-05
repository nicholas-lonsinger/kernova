import Foundation

/// Why a transport refused a request before any verb could run.
///
/// Distinct from ``CommandErrorDTO``, which is a verb's own answer: these are
/// the envelope's, raised by the transport or the router while the request was
/// still bytes. A client that receives one learns its request was never
/// dispatched.
public enum VMCommandTransportRefusal: Error, Codable, Sendable, Hashable {
    /// The peer is not one this build answers — `reason` says what the check
    /// found, in the words a client can show.
    case authorizationRefused(reason: String)
    /// The peer speaks a different version of the vocabulary.
    case unsupportedProtocolVersion(peer: Int, expected: Int)
    /// The bytes are not a request this build can read.
    case undecodableRequest(String)
}
