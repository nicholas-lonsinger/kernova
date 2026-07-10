import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.residentProvenanceLine(bundlePath:build:configuration:)`.
///
/// The pure formatter behind the resident app's startup `.notice` log line
/// (#455). The XPC peer pin on the File Provider servicing connection checks
/// only identifier + team, so a mismatched-version interaction between two
/// installed copies is otherwise only diagnosable by correlating logs across
/// processes; this one greppable line makes "which copy is this" legible.
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
