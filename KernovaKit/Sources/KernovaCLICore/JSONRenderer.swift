import Foundation

/// The wire DTOs as JSON, for a script.
///
/// The DTOs are encoded directly rather than reshaped: the tool's JSON and the
/// wire's are one schema, so nothing here can drift from what the app sends.
/// Keys are sorted and dates are ISO 8601, so a diff of two runs shows what
/// changed rather than how the encoder felt.
enum JSONRenderer {
    /// Encodes any wire payload.
    static func render(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIFailure(.operationFailed, "The answer could not be rendered as JSON.")
        }
        return text
    }
}
