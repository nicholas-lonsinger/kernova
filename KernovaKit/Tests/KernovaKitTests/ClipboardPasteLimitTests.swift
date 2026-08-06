import Testing

@testable import KernovaKit

@Suite("ClipboardPasteLimit")
struct ClipboardPasteLimitTests {
    /// Binary multiplier for each unit the display renderer can pick.
    private static let multipliers: [String: Double] = [
        "bytes": 1, "KB": 1024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776,
    ]

    // MARK: - The ladder

    @Test("the offered ceilings ascend and include the default")
    func choicesAscendAndIncludeTheDefault() {
        #expect(ClipboardPasteLimit.choices == ClipboardPasteLimit.choices.sorted())
        #expect(Set(ClipboardPasteLimit.choices).count == ClipboardPasteLimit.choices.count)
        #expect(ClipboardPasteLimit.choices.contains(ClipboardPasteLimit.defaultBytes))
        #expect(ClipboardPasteLimit.choices.allSatisfy { $0 > 0 })
    }

    // MARK: - resolve

    @Test("no stored preference resolves to the default")
    func resolveNilIsTheDefault() {
        #expect(ClipboardPasteLimit.resolve(nil) == ClipboardPasteLimit.defaultBytes)
    }

    @Test("every offered ceiling resolves to itself")
    func resolveIsIdentityOnTheLadder() {
        for choice in ClipboardPasteLimit.choices {
            #expect(ClipboardPasteLimit.resolve(choice) == choice)
        }
    }

    @Test("a value between stops resolves to the nearer one")
    func resolveSnapsBetweenStops() {
        // Just above 1 GiB is nearer 1 GiB than 2 GiB.
        let oneGiB = 1024 * 1024 * 1024
        #expect(ClipboardPasteLimit.resolve(oneGiB + 1) == oneGiB)
        // Just below 2 GiB is nearer 2 GiB.
        #expect(
            ClipboardPasteLimit.resolve(ClipboardPasteLimit.defaultBytes - 1)
                == ClipboardPasteLimit.defaultBytes)
    }

    @Test("a value past either end of the ladder clamps onto it")
    func resolveClampsOutOfRange() throws {
        let smallest = try #require(ClipboardPasteLimit.choices.first)
        let largest = try #require(ClipboardPasteLimit.choices.last)
        #expect(ClipboardPasteLimit.resolve(1) == smallest)
        #expect(ClipboardPasteLimit.resolve(0) == smallest)
        #expect(ClipboardPasteLimit.resolve(-1) == smallest)
        #expect(ClipboardPasteLimit.resolve(Int.max) == largest)
    }

    // MARK: - fromPolicy

    @Test("an unset policy field leaves the receiver on its own default")
    func fromPolicyTreatsZeroAsUnset() {
        // Reading `0` literally would be a ceiling of zero bytes — every paste
        // refused — rather than "the host said nothing".
        #expect(ClipboardPasteLimit.fromPolicy(0) == ClipboardPasteLimit.defaultBytes)
    }

    @Test("a pushed ceiling is honored as sent")
    func fromPolicyHonorsAPushedCeiling() {
        for choice in ClipboardPasteLimit.choices {
            #expect(ClipboardPasteLimit.fromPolicy(UInt64(choice)) == choice)
        }
    }

    @Test("a policy value past Int's range clamps instead of trapping")
    func fromPolicyClampsAnOversizedValue() {
        #expect(ClipboardPasteLimit.fromPolicy(UInt64.max) == Int.max)
    }

    // MARK: - displayLimit

    @Test("the display string renders the ceiling it is given")
    func displayLimitRendersTheCeiling() throws {
        #expect(ClipboardPasteLimit.displayLimit(ClipboardPasteLimit.defaultBytes) == "2 GB")
        #expect(ClipboardPasteLimit.displayLimit(512 * 1024 * 1024) == "512 MB")
        #expect(ClipboardPasteLimit.displayLimit(16 * 1024 * 1024 * 1024) == "16 GB")
        // Halves keep one decimal place rather than rounding away.
        #expect(ClipboardPasteLimit.displayLimit(1536 * 1024 * 1024) == "1.5 GB")
    }

    @Test("every offered ceiling renders back to its own byte count")
    func displayLimitIsDerivedForEveryChoice() throws {
        // Derived, not typed: the rendered figure times its binary unit is the
        // ceiling, so adding a stop the renderer mangles fails here rather than
        // shipping a wrong figure into the copy that names the limit.
        for choice in ClipboardPasteLimit.choices {
            let parts = ClipboardPasteLimit.displayLimit(choice).split(separator: " ")
            #expect(parts.count == 2)
            let value = try #require(Double(parts[0]))
            let multiplier = try #require(Self.multipliers[String(parts[1])])
            #expect(value * multiplier == Double(choice))
        }
    }

    // MARK: - estimatedStreamSeconds

    @Test("the estimate is the ceiling over the measured throughput")
    func estimateDividesByThroughput() {
        let throughput = ClipboardPasteLimit.measuredThroughputBytesPerSecond
        #expect(ClipboardPasteLimit.estimatedStreamSeconds(throughput * 10) == 10)
        // 2 GiB at 366 MiB/s.
        #expect(ClipboardPasteLimit.estimatedStreamSeconds(ClipboardPasteLimit.defaultBytes) == 6)
    }

    @Test("a sub-second payload still reads as one second, never zero")
    func estimateFloorsAtOneSecond() {
        #expect(ClipboardPasteLimit.estimatedStreamSeconds(1) == 1)
        #expect(ClipboardPasteLimit.estimatedStreamSeconds(0) == 1)
    }
}
