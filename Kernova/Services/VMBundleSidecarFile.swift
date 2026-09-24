import Foundation

/// A JSON file a VM bundle holds beside its `config.json` — the host state, the
/// snapshot manifest, the USB accessory pairings — in the `config.json` coding.
///
/// Absence is the one outcome that reads as "nothing recorded". A file that is
/// present but cannot be read or decoded throws ``Unreadable``, so no caller can
/// mistake it for the defaults a later write would put over it.
enum VMBundleSidecarFile {
    /// A file that is present but could not be read or decoded.
    struct Unreadable: LocalizedError {
        let fileName: String
        let underlying: any Error

        var errorDescription: String? {
            "\u{201C}\(fileName)\u{201D} could not be read: \(underlying.localizedDescription)"
        }
    }

    /// The file's value, or `nil` when the bundle holds no such file.
    static func read<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value? {
        do {
            return try VMConfiguration.makeJSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return nil
        } catch {
            throw Unreadable(fileName: url.lastPathComponent, underlying: error)
        }
    }

    /// Replaces the file with `value`.
    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try VMConfiguration.makeJSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}
