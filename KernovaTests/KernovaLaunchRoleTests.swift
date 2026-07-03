import Testing

@testable import Kernova

/// Unit tests for `KernovaLaunchRole.resolve(arguments:environment:)` — the pure
/// function that decides whether the Kernova executable is the resident
/// launchd-managed agent, a short-lived launcher, or the plain foreground app the
/// unit-test host runs.
@Suite("KernovaLaunchRole")
struct KernovaLaunchRoleTests {
    private static let testEnv = ["XCTestConfigurationFilePath": "/tmp/whatever.xctestconfiguration"]

    @Test("A bare double-click (no flag, not under tests) is the launcher")
    func bareLaunchIsLauncher() {
        #expect(
            KernovaLaunchRole.resolve(arguments: ["Kernova"], environment: [:]) == .launcher)
    }

    @Test("The --background flag (passed only by the plist) selects the resident agent")
    func backgroundFlagIsAgent() {
        #expect(
            KernovaLaunchRole.resolve(arguments: ["Kernova", "--background"], environment: [:])
                == .backgroundAgent)
    }

    @Test("The XCTest environment forces the foreground-for-testing role")
    func underTestsIsForeground() {
        #expect(
            KernovaLaunchRole.resolve(arguments: ["Kernova"], environment: Self.testEnv)
                == .foregroundForTesting)
    }

    @Test("Test detection wins over --background so the test host never hosts a Mach service")
    func testsBeatBackgroundFlag() {
        #expect(
            KernovaLaunchRole.resolve(
                arguments: ["Kernova", "--background"], environment: Self.testEnv)
                == .foregroundForTesting)
    }

    @Test("The --foreground flag selects the developer foreground-GUI role")
    func foregroundFlagIsForeground() {
        #expect(
            KernovaLaunchRole.resolve(arguments: ["Kernova", "--foreground"], environment: [:])
                == .foreground)
    }

    @Test("The --register-agent flag selects the explicit register-this-copy role")
    func registerAgentFlagIsRegisterAgent() {
        #expect(
            KernovaLaunchRole.resolve(arguments: ["Kernova", "--register-agent"], environment: [:])
                == .registerAgent)
    }

    @Test("Test detection wins over --register-agent so a test run never registers the login agent")
    func testsBeatRegisterAgentFlag() {
        #expect(
            KernovaLaunchRole.resolve(
                arguments: ["Kernova", "--register-agent"], environment: Self.testEnv)
                == .foregroundForTesting)
    }

    @Test("Test detection wins over --foreground")
    func testsBeatForegroundFlag() {
        #expect(
            KernovaLaunchRole.resolve(
                arguments: ["Kernova", "--foreground"], environment: Self.testEnv)
                == .foregroundForTesting)
    }

    @Test("--background outranks --register-agent when both are present")
    func backgroundOutranksRegisterAgent() {
        #expect(
            KernovaLaunchRole.resolve(
                arguments: ["Kernova", "--register-agent", "--background"], environment: [:])
                == .backgroundAgent)
    }

    @Test("--register-agent outranks --foreground when both are present")
    func registerAgentOutranksForeground() {
        #expect(
            KernovaLaunchRole.resolve(
                arguments: ["Kernova", "--foreground", "--register-agent"], environment: [:])
                == .registerAgent)
    }
}
