import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.residentProvenanceLine(bundlePath:build:configuration:)`.
///
/// The pure formatter behind the resident app's startup `.notice` log line
/// (#455). Launch Services elects among every on-disk copy by `CFBundleVersion`,
/// so the copy that actually launched need not be the one the developer
/// expected; this one greppable line makes "which copy is this" legible from the
/// log alone.
@Suite("AppDelegate.residentProvenanceLine")
struct AppDelegateProvenanceTests {
    @Test("formats bundle path, build, and configuration into one line")
    func formatsAllFields() {
        #expect(
            AppDelegate.residentProvenanceLine(
                bundlePath: "/Applications/Kernova.app",
                build: "142",
                configuration: "Release")
                == "bundle=/Applications/Kernova.app build=142 config=Release")
    }

    @Test("tolerates a missing build number without crashing")
    func missingBuildNumberFallback() {
        #expect(
            AppDelegate.residentProvenanceLine(
                bundlePath: "/Applications/Kernova.app",
                build: "?",
                configuration: "Debug")
                == "bundle=/Applications/Kernova.app build=? config=Debug")
    }
}
