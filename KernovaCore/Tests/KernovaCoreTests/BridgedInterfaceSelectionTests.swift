import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("BridgedInterfaceSelection Tests", .caseScoped)
struct BridgedInterfaceSelectionTests {
    private static let identifiers = ["en0", "en1"]

    /// Every host state the resolver can see over two interfaces: each
    /// subset offered, a primary that is one of them, neither, or none, and
    /// a held bridge on either or none.
    private static var hostStates: [(held: String?, available: [String], primary: String?)] {
        let subsets: [[String]] = [[], ["en0"], ["en1"], ["en0", "en1"]]
        let primaries: [String?] = [nil, "en0", "en1", "utun4"]
        let helds: [String?] = [nil, "en0", "en1"]
        return subsets.flatMap { available in
            primaries.flatMap { primary in helds.map { (held: $0, available: available, primary: primary) } }
        }
    }

    @Test("A chosen interface is bridged while offered and nothing else is ever put in its place")
    func chosenInterfaceIsNeverSubstituted() {
        for persisted in Self.identifiers {
            for state in Self.hostStates {
                let resolved = BridgedInterfaceSelection.interface(
                    persisted: persisted, held: state.held, available: state.available, primary: state.primary)
                #expect(
                    resolved == (state.available.contains(persisted) ? persisted : nil),
                    "persisted \(persisted), \(state)")
            }
        }
    }

    @Test("Automatic resolves only to an interface the host offers")
    func automaticResolvesOnlyToAnOfferedInterface() {
        for state in Self.hostStates {
            let resolved = BridgedInterfaceSelection.interface(
                persisted: nil, held: state.held, available: state.available, primary: state.primary)
            if let resolved { #expect(state.available.contains(resolved), "\(state)") }
        }
    }

    @Test(
        "Automatic keeps a held bridge, else takes a bridgeable default route, else resolves to nothing",
        arguments: [
            // The held bridge's interface is still offered: kept across a
            // default-route change.
            (held: "en0", available: ["en0", "en1"], primary: "en1", expected: "en0"),
            // The held bridge's interface left: the default route.
            (held: "en0", available: ["en1"], primary: "en1", expected: "en1"),
            // Nothing held: the default route.
            (held: nil, available: ["en0", "en1"], primary: "en1", expected: "en1"),
            // The default route isn't bridgeable.
            (held: nil, available: ["en0", "en1"], primary: "utun4", expected: nil),
            // No default route.
            (held: nil, available: ["en0"], primary: nil, expected: nil),
            // No interfaces at all.
            (held: "en0", available: [], primary: "en0", expected: nil),
        ] as [(held: String?, available: [String], primary: String?, expected: String?)])
    func automatic(held: String?, available: [String], primary: String?, expected: String?) {
        #expect(
            BridgedInterfaceSelection.interface(persisted: nil, held: held, available: available, primary: primary)
                == expected)
    }
}
