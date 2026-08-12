import Testing

@testable import Kernova

/// Unit tests for `LaunchPosture` — the argv-derived launch decision `main()`
/// makes before AppKit checkin (#796).
@Suite("LaunchPosture")
struct LaunchPostureTests {
    private static let executable = "/Applications/Kernova.app/Contents/MacOS/Kernova"

    // MARK: - init(arguments:)

    @Test("the helper's argv — flag after argv[0] — is a login launch")
    func helperArgumentsAreLoginLaunch() {
        #expect(
            LaunchPosture(arguments: [Self.executable, LaunchPosture.loginLaunchFlag])
                == .loginLaunch)
    }

    @Test("the flag is the literal the login helper passes")
    func flagValueIsStable() {
        // KernovaLoginHelper/main.swift carries its own copy of this literal —
        // a synchronized root group spans one folder, so the two targets cannot
        // share the declaration.
        #expect(LaunchPosture.loginLaunchFlag == "--login-launch")
    }

    @Test("the flag is matched at any index, not a fixed one")
    func flagMatchedAtAnyIndex() {
        #expect(
            LaunchPosture(arguments: [Self.executable, "-NSDocumentRevisionsDebugMode", "--login-launch"])
                == .loginLaunch)
        #expect(LaunchPosture(arguments: ["--login-launch"]) == .loginLaunch)
    }

    @Test("an executable path alone is a manual launch")
    func executableOnlyIsManual() {
        #expect(LaunchPosture(arguments: [Self.executable]) == .manual)
    }

    @Test("an empty argv is a manual launch")
    func emptyArgumentsAreManual() {
        #expect(LaunchPosture(arguments: []) == .manual)
    }

    @Test("near-miss spellings of the flag are manual launches")
    func nearMissFlagsAreManual() {
        for argument in ["--login-launch=1", "-login-launch", "--login-launcher", "login-launch"] {
            #expect(LaunchPosture(arguments: [Self.executable, argument]) == .manual)
        }
    }

    // MARK: - yields(toRunningInstance:)

    @Test("a login launch yields only when another instance is already running")
    func loginLaunchYieldsToRunningInstance() {
        #expect(LaunchPosture.loginLaunch.yields(toRunningInstance: true))
        #expect(!LaunchPosture.loginLaunch.yields(toRunningInstance: false))
    }

    @Test("a manual launch never yields")
    func manualLaunchNeverYields() {
        #expect(!LaunchPosture.manual.yields(toRunningInstance: true))
        #expect(!LaunchPosture.manual.yields(toRunningInstance: false))
    }
}
