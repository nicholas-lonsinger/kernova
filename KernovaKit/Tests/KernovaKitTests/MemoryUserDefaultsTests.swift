import Foundation
import KernovaTestSupport
import Testing

/// What every test reading preferences through `makeTestDefaults` rests on:
/// Foundation's typed accessors still resolve through the overridden trio, and
/// a write reaches no domain another process can read.
@Suite("MemoryUserDefaults", .admissionGated)
struct MemoryUserDefaultsTests {
    @Test("Typed accessors read back what the typed setters wrote")
    func typedAccessorsResolveThroughTheOverrides() {
        let defaults = makeTestDefaults()

        defaults.set(true, forKey: "flag")
        defaults.set("text", forKey: "name")
        defaults.set(["a", "b"], forKey: "list")
        defaults.set(7, forKey: "count")

        #expect(defaults.bool(forKey: "flag") == true)
        #expect(defaults.object(forKey: "flag") as? Bool == true)
        #expect(defaults.string(forKey: "name") == "text")
        #expect(defaults.stringArray(forKey: "list") == ["a", "b"])
        #expect(defaults.array(forKey: "list") as? [String] == ["a", "b"])
        #expect(defaults.integer(forKey: "count") == 7)
        #expect(defaults.object(forKey: "count") as? Int == 7)
    }

    @Test("An unset key reads back as the accessor's empty value")
    func unsetKeysReadAsEmpty() {
        let defaults = makeTestDefaults()

        #expect(defaults.bool(forKey: "absent") == false)
        #expect(defaults.string(forKey: "absent") == nil)
        #expect(defaults.stringArray(forKey: "absent") == nil)
        #expect(defaults.integer(forKey: "absent") == 0)
        #expect(defaults.object(forKey: "absent") == nil)
    }

    @Test("Setting nil clears the key")
    func settingNilClearsTheKey() {
        let defaults = makeTestDefaults()
        defaults.set("text", forKey: "name")

        defaults.set(nil, forKey: "name")

        #expect(defaults.string(forKey: "name") == nil)
        #expect(defaults.object(forKey: "name") == nil)
    }

    @Test("A write reaches neither the suite's own domain nor a plist")
    func writesReachNoPersistentDomain() throws {
        let key = "memoryUserDefaultsOnlyKey"
        let defaults = makeTestDefaults()

        defaults.set("written", forKey: key)

        let domain = try #require(UserDefaults(suiteName: MemoryUserDefaults.suiteName))
        #expect(domain.string(forKey: key) == nil)

        let library = try #require(
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
        let plist = library.appendingPathComponent(
            "Preferences/\(MemoryUserDefaults.suiteName).plist")
        #expect(FileManager.default.fileExists(atPath: plist.path) == false)
    }

    @Test("Two stores do not observe each other")
    func storesAreIndependent() {
        let first = makeTestDefaults()
        let second = makeTestDefaults()

        first.set("first", forKey: "name")

        #expect(second.string(forKey: "name") == nil)
        #expect(first.string(forKey: "name") == "first")
    }
}
