import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.residentProvenanceLine`.
///
/// The pure formatter behind the resident app's startup `.notice` log line
/// (#455). Launch Services elects among every on-disk copy by `CFBundleVersion`,
/// so the copy that actually launched need not be the one the developer
/// expected; this one greppable line makes "which copy is this" legible from the
/// log alone.
@Suite("AppDelegate.residentProvenanceLine", .admissionGated)
struct AppDelegateProvenanceTests {
    @Test("formats bundle path, build, configuration, and entitlement state into one line")
    func formatsAllFields() {
        #expect(
            AppDelegate.residentProvenanceLine(
                bundlePath: "/Applications/Kernova.app",
                build: "142",
                configuration: "Release",
                vmNetworkingEntitled: true)
                == "bundle=/Applications/Kernova.app build=142 config=Release vmNetworking=entitled")
    }

    @Test("reports an unentitled signature")
    func unentitledSignature() {
        #expect(
            AppDelegate.residentProvenanceLine(
                bundlePath: "/Applications/Kernova.app",
                build: "142",
                configuration: "Debug",
                vmNetworkingEntitled: false)
                == "bundle=/Applications/Kernova.app build=142 config=Debug vmNetworking=unentitled")
    }

    @Test("tolerates a missing build number without crashing")
    func missingBuildNumberFallback() {
        #expect(
            AppDelegate.residentProvenanceLine(
                bundlePath: "/Applications/Kernova.app",
                build: "?",
                configuration: "Debug",
                vmNetworkingEntitled: false)
                == "bundle=/Applications/Kernova.app build=? config=Debug vmNetworking=unentitled")
    }
}
