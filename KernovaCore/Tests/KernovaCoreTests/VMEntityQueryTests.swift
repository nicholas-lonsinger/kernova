import AppIntents
import Testing

@testable import KernovaCore

/// The query Find Virtual Machine runs: that it is Kernova's to run, and
/// what it refuses.
@Suite("VM Entity Query Tests")
struct VMEntityQueryTests {
    /// Shortcuts filters an `EnumerableEntityQuery`'s entities itself, as its
    /// documentation says, so none of Find's conditions would run: a shortcut
    /// finding VMs by State Group got none on a library of stopped VMs, and
    /// one naming a network or tag Kernova doesn't have gets none instead of
    /// failing — and its next action acts on that set.
    @Test("Find Virtual Machine is no query Shortcuts filters itself")
    func findIsNotFilteredByShortcuts() {
        #expect(Self.isEnumerable(VMEntityQuery.self) == false)
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
