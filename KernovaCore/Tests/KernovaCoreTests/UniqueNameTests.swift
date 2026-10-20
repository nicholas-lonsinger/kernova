import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("UniqueName Tests", .caseScoped)
struct UniqueNameTests {
    @Test("climbs to the first free numbered suffix")
    func climbs() {
        #expect(UniqueName.firstAvailable(prefix: "VM", existing: ["VM"]) == "VM 2")
        #expect(UniqueName.firstAvailable(prefix: "VM", existing: ["VM", "VM 2"]) == "VM 3")
    }

    @Test("the counter follows the whole prefix, dots included")
    func countsAfterDottedPrefix() {
        #expect(
            UniqueName.firstAvailable(prefix: "macOS 15.1 Copy", existing: ["macOS 15.1 Copy"])
                == "macOS 15.1 Copy 2")
        #expect(UniqueName.firstAvailable(prefix: "disk.img", existing: ["disk.img"]) == "disk.img 2")
    }

    @Test("case-sensitive by default: differing case is not a collision")
    func caseSensitiveDefault() {
        #expect(UniqueName.firstAvailable(prefix: "vm", existing: ["VM"]) == "vm")
    }

    @Test("caseInsensitive treats differing case as taken but keeps the prefix's casing (#498)")
    func caseInsensitive() {
        #expect(UniqueName.firstAvailable(prefix: "foo", existing: ["Foo"], caseInsensitive: true) == "foo 2")
        #expect(
            UniqueName.firstAvailable(prefix: "Foo", existing: ["foo", "FOO 2"], caseInsensitive: true)
                == "Foo 3")
    }
}
