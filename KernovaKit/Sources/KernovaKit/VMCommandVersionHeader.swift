import Foundation

/// The one field every command frame carries in every vocabulary — a request
/// and a response alike.
///
/// Read before the rest of a frame: a frame in another vocabulary may not
/// decode as this build's ``VMCommandRequest`` or ``VMCommandResponse``, and
/// its sender is owed the version answer, not a decoding failure.
public struct VMCommandVersionHeader: Decodable, Sendable {
    /// The vocabulary the frame is written in.
    public let protocolVersion: Int

    /// Reads the version of the frame in `data`.
    public static func protocolVersion(of data: Data) throws -> Int {
        try JSONDecoder().decode(Self.self, from: data).protocolVersion
    }
}
