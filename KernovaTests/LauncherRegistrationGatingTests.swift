import Foundation
import ServiceManagement
import Testing

@testable import Kernova

/// Unit tests for `LauncherAppDelegate.launcherAction(...)` and
/// `isInstalledInApplications(...)`, the pure decisions that gate background-agent
/// registration to intentional installs (issue #451).
///
/// Modeled on the injected-input matrix style of `AppDelegateQuitClassificationTests`.
/// The whole point of the gate: a Debug build (worktree/DerivedData/Downloads copy)
/// must never auto-register the login agent — doing so pins launchd's BTM record to
/// a path that later gets deleted, bricking every summon. Release auto-registers only
/// from `/Applications`. Build configuration is injected as a `Bool` so this Debug
/// test host can exercise the Release half of the matrix.
@Suite("LauncherAppDelegate registration gating")
struct LauncherRegistrationGatingTests {
    // MARK: - launcherAction: an already-registered agent is location/build-agnostic

    @Test(
        "An enabled agent is summoned in every build and location",
        arguments: [true, false], [true, false])
    func enabledIsSummon(isRelease: Bool, inApps: Bool) {
        #expect(
            LauncherAppDelegate.launcherAction(
                isReleaseBuild: isRelease, isInApplications: inApps, status: .enabled) == .summon)
    }

    @Test(
        "A disabled (requires-approval) agent prompts for approval in every build and location",
        arguments: [true, false], [true, false])
    func requiresApprovalIsPrompt(isRelease: Bool, inApps: Bool) {
        #expect(
            LauncherAppDelegate.launcherAction(
                isReleaseBuild: isRelease, isInApplications: inApps, status: .requiresApproval)
                == .promptApproval)
    }

    // MARK: - launcherAction: the unregistered case is where the gate lives

    @Test(
        "A Debug build with no agent is a dead end regardless of location — it never auto-registers",
        arguments: [true, false])
    func debugUnregisteredIsDeadEnd(inApps: Bool) {
        #expect(
            LauncherAppDelegate.launcherAction(
                isReleaseBuild: false, isInApplications: inApps, status: .notRegistered)
                == .reportUnregisteredDebug)
    }

    @Test("A Release build in /Applications with no agent registers")
    func releaseUnregisteredInApplicationsRegisters() {
        #expect(
            LauncherAppDelegate.launcherAction(
                isReleaseBuild: true, isInApplications: true, status: .notRegistered) == .register)
    }

    @Test("A Release build outside /Applications with no agent refuses to self-register")
    func releaseUnregisteredOutsideApplicationsReports() {
        #expect(
            LauncherAppDelegate.launcherAction(
                isReleaseBuild: true, isInApplications: false, status: .notRegistered)
                == .reportNotInApplications)
    }

    // MARK: - launcherAction: .notFound is treated like .notRegistered (the default branch)

    @Test("A .notFound status is a Debug dead end, same as .notRegistered")
    func notFoundDebugIsDeadEnd() {
        #expect(
            LauncherAppDelegate.launcherAction(
                isReleaseBuild: false, isInApplications: true, status: .notFound)
                == .reportUnregisteredDebug)
    }

    @Test("A .notFound status in a Release /Applications build registers, same as .notRegistered")
    func notFoundReleaseInApplicationsRegisters() {
        #expect(
            LauncherAppDelegate.launcherAction(
                isReleaseBuild: true, isInApplications: true, status: .notFound) == .register)
    }

    // MARK: - isInstalledInApplications

    @Test(
        "Only the system /Applications folder counts as installed",
        arguments: [
            ("/Applications/Kernova.app", true),
            ("/Applications/Sub/Kernova.app", true),
            ("/Users/dev/Downloads/Kernova.app", false),
            ("/Users/dev/Applications/Kernova.app", false),
            ("/ApplicationsFoo/Kernova.app", false),
            ("/private/var/folders/ab/xyz/AppTranslocation/UUID/d/Kernova.app", false),
        ])
    func installLocation(path: String, expected: Bool) {
        #expect(
            LauncherAppDelegate.isInstalledInApplications(URL(fileURLWithPath: path)) == expected)
    }
}
