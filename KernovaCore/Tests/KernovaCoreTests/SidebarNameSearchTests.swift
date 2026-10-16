import KernovaCore
import KernovaTestSupport
import Testing

/// What the sidebar's name search matches.
@Suite("Sidebar name search matching", .caseScoped)
struct SidebarNameSearchTests {
    private func search(_ text: String) -> SidebarNameSearch { SidebarNameSearch(text: text) }

    @Test("A name matches when it contains the trimmed term, ignoring case and diacritics")
    func matching() {
        #expect(search("ubu").admits("Ubuntu Server"))
        #expect(search("  server ").admits("Ubuntu Server"))
        #expect(search("cafe").admits("Café Lab"))
        #expect(!search("sonoma").admits("Ubuntu Server"))
        #expect(search("   ").admits("Anything"))
        #expect(!search("   ").isActive)
    }

    @Test("The best match is the name equal to the term, then one it begins, then the first that contains it")
    func bestMatch() {
        let names = ["Old Ubuntu", "Ubuntu Server", "ubuntu"]
        #expect(search("Ubuntu").bestMatch(in: names, name: { $0 }) == "ubuntu")
        #expect(search("Ubuntu S").bestMatch(in: names, name: { $0 }) == "Ubuntu Server")
        #expect(search("buntu").bestMatch(in: names, name: { $0 }) == "Old Ubuntu")
        #expect(search("Sequoia").bestMatch(in: names, name: { $0 }) == nil)
        #expect(search("").bestMatch(in: names, name: { $0 }) == nil)
    }
}
