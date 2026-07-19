import Testing

@testable import KernovaKit

/// `KernovaCapability.logDescription(of:)` — the #145 log-redaction helper that
/// keeps peer-supplied capability strings out of the persisted log while
/// keeping recognized tags diagnosable.
@Suite("KernovaCapability")
struct KernovaCapabilityTests {
    @Test("Recognized tags render verbatim in offer order")
    func recognizedTagsRenderVerbatim() {
        #expect(
            KernovaCapability.logDescription(of: KernovaCapability.controlChannelDefaults)
                == KernovaCapability.controlChannelDefaults.joined(separator: ","))
    }

    @Test("Unrecognized tags are reduced to a count")
    func unrecognizedTagsAreCounted() {
        let capabilities = [
            KernovaCapability.controlV1,
            "evil\ninjected line",
            KernovaCapability.clipboardStreamV1,
            "another-unknown",
        ]
        #expect(
            KernovaCapability.logDescription(of: capabilities)
                == "control.v1,clipboard.stream.v1 +2 unrecognized")
    }

    @Test("An all-unrecognized list renders only the count")
    func allUnrecognizedRendersCountOnly() {
        #expect(KernovaCapability.logDescription(of: ["x", "y"]) == "+2 unrecognized")
    }

    @Test("An empty list renders empty")
    func emptyListRendersEmpty() {
        #expect(KernovaCapability.logDescription(of: []).isEmpty)
    }

    @Test("Duplicate recognized tags collapse, so output stays bounded")
    func duplicatesCollapse() {
        let capabilities =
            Array(repeating: KernovaCapability.controlV1, count: 100) + ["junk"]
        #expect(KernovaCapability.logDescription(of: capabilities) == "control.v1 +1 unrecognized")
    }
}
