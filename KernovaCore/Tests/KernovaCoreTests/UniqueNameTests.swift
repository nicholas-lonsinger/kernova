import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("UniqueName Tests", .caseScoped)
struct UniqueNameTests {
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
