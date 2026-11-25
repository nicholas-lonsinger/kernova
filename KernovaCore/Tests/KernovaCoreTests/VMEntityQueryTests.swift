import AppIntents
import Testing

@testable import KernovaCore

/// The queries Shortcuts' Find actions run: that each is Kernova's to run,
/// and what they refuse.
@Suite("VM Entity Query Tests")
struct VMEntityQueryTests {
    /// Shortcuts filters an `EnumerableEntityQuery`'s entities itself, as its
    /// documentation says, so none of a Find's conditions would run: a
    /// shortcut finding VMs by State Group got none on a library of stopped
    /// VMs, one naming a network or tag Kernova doesn't have gets none
    /// instead of failing, and a name matches under Shortcuts' rule rather
    /// than Kernova's — and its next action acts on that set. The setting-key
    /// query is outside it: its entity has no properties to filter by.
    @Test("No Find with properties to filter by is a query Shortcuts filters itself")
    func findIsNotFilteredByShortcuts() {
        #expect(Self.isEnumerable(VMEntityQuery.self) == false)
        #expect(Self.isEnumerable(NetworkEntityQuery.self) == false)
        #expect(Self.isEnumerable(VMGroupEntityQuery.self) == false)
    }

    private static func isEnumerable(_ query: Any.Type) -> Bool {
        query is any EnumerableEntityQuery.Type
    }

    /// `prefix` traps on a negative count, so a Find handed one would take
    /// Kernova down, and every running guest's unsaved work with it.
    @Test("A Find's negative limit is refused")
    func negativeLimitIsRefused() {
        #expect(throws: CommandError.self) { try VMEntityQuery.ordered([], by: [], limit: -1) }
    }
}
