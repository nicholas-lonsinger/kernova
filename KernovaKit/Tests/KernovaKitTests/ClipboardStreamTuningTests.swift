import Testing

@testable import KernovaKit

@Suite("ClipboardStreamTuning")
struct ClipboardStreamTuningTests {
    /// Binary multiplier for each unit the display renderer can pick.
    private static let multipliers: [String: Double] = [
        "bytes": 1, "KB": 1024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776,
    ]

    @Test("the user-facing limit string renders the deadline-safe cap itself")
    func displayLimitRendersTheCap() throws {
        let limit = ClipboardStreamTuning.maxDeadlineSafePasteDisplayLimit
        // What every surface naming the limit reads today.
        #expect(limit == "2 GB")

        // Derived, not typed: the rendered figure times its binary unit is the
        // cap, so retuning `maxDeadlineSafePasteBytes` without moving the copy
        // fails here rather than shipping a stale limit to the user.
        let parts = limit.split(separator: " ")
        #expect(parts.count == 2)
        let value = try #require(Double(parts[0]))
        let multiplier = try #require(Self.multipliers[String(parts[1])])
        #expect(value * multiplier == Double(ClipboardStreamTuning.maxDeadlineSafePasteBytes))
    }
}
