import Testing

@testable import Kernova

@Suite("UniqueName Tests")
struct UniqueNameTests {
    @Test("returns the prefix unchanged when it's free")
    func freePrefix() {
        #expect(UniqueName.firstAvailable(prefix: "VM", existing: []) == "VM")
        #expect(UniqueName.firstAvailable(prefix: "VM", existing: ["Other"]) == "VM")
    }

    @Test("climbs to the first free numbered suffix")
    func climbs() {
        #expect(UniqueName.firstAvailable(prefix: "VM", existing: ["VM"]) == "VM 2")
        #expect(UniqueName.firstAvailable(prefix: "VM", existing: ["VM", "VM 2"]) == "VM 3")
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
