#if os(macOS)
import Foundation
import KernovaAgentCore
import KernovaAgentInstall
import KernovaTestSupport
import Testing

@testable import KernovaPlatformDarwin

@Suite("The macOS install plan and its launchd property lists", .caseScoped)
struct LaunchdJobsTests {
    static let user = MacInstallLayout.user(home: "/Users/pbear", userID: 501)
    static let system = MacInstallLayout.system(consoleUserID: 501)
    static let tool = "/Volumes/Kernova Guest Agent/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent"
    static let userRoot = "/Users/pbear/Library/Application Support/Kernova/Guest Agent"
    static let systemRoot = "/Library/Application Support/Kernova/Guest Agent"

    @Test("\"For everyone\" adds the system peer's LaunchDaemon, and bootstraps each list into its own domain")
    func systemPlan() {
        let plan = InstallPlan.install(Self.system, stopTool: Self.tool)
        #expect(
            InstallPlan.dryRun(plan, heading: "install --system will:") == [
                "install --system will:",
                "  run '\(Self.tool)' stop-service system/app.kernova.macosagent.system.rollback",
                "  run '\(Self.tool)' stop-service system/app.kernova.macosagent.system",
                "  run '\(Self.tool)' stop-service gui/501/app.kernova.macosagent.session",
                "  remove \(Self.systemRoot)/switch-pending, if present",
                "  remove \(Self.systemRoot)/switch-rejected, if present",
                "  make directory \(Self.systemRoot), if missing",
                "  make directory \(Self.systemRoot)/slots, if missing",
                "  write the agent as Kernova Guest Agent.app in the slot under \(Self.systemRoot)/slots that "
                    + "\(Self.systemRoot)/current does not name, record it in \(Self.systemRoot)/state.json, point "
                    + "\(Self.systemRoot)/rollback at it, and switch \(Self.systemRoot)/current to it",
                "  make directory /Library/LaunchAgents, if missing",
                "  write /Library/LaunchAgents/app.kernova.macosagent.session.plist",
                "  make directory /Library/LaunchDaemons, if missing",
                "  write /Library/LaunchDaemons/app.kernova.macosagent.system.plist",
                "  write /Library/LaunchDaemons/app.kernova.macosagent.system.rollback.plist",
                "  run launchctl bootstrap system /Library/LaunchDaemons/app.kernova.macosagent.system.rollback.plist",
                "  run launchctl bootstrap system /Library/LaunchDaemons/app.kernova.macosagent.system.plist",
                "  run launchctl bootstrap gui/501 /Library/LaunchAgents/app.kernova.macosagent.session.plist",
            ])
    }

    @Test("The system peer's LaunchDaemon runs the agent's system peer through current")
    func systemPlist() {
        let plist = Self.parse(LaunchdPlists.system(Self.system))
        #expect(plist["Label"] as? String == "app.kernova.macosagent.system")
        #expect(
            plist["ProgramArguments"] as? [String] == [
                Self.systemRoot + "/current/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent", "system",
            ])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(plist["LimitLoadToSessionType"] == nil && plist["UserName"] == nil)
    }

    @Test("The rollback check runs the rollback slot's agent every check interval")
    func rollbackPlists() {
        let user = Self.parse(LaunchdPlists.rollback(Self.user))
        #expect(user["Label"] as? String == "app.kernova.macosagent.rollback")
        #expect(user["StartInterval"] as? Int == UpdateRollbackPolicy.checkIntervalSeconds)
        #expect(user["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(user["RunAtLoad"] == nil && user["KeepAlive"] == nil)
        #expect(
            user["ProgramArguments"] as? [String] == [
                Self.userRoot + "/rollback/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent", "rollback-check",
                "--scope", "user",
            ])
        let system = Self.parse(LaunchdPlists.rollback(Self.system))
        #expect(system["Label"] as? String == "app.kernova.macosagent.system.rollback")
        #expect(
            system["ProgramArguments"] as? [String] == [
                Self.systemRoot + "/rollback/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent",
                "rollback-check", "--scope", "system",
            ])
        #expect(system["LimitLoadToSessionType"] == nil)
    }

    @Test("Markup in a path is escaped")
    func escaping() {
        let layout = MacInstallLayout.user(home: "/Users/a&b<c>", userID: 502)
        #expect(
            (Self.parse(LaunchdPlists.session(layout))["ProgramArguments"] as? [String])?.first
                == "/Users/a&b<c>/" + MacInstallLayout.userRootBelowHome
                + "/current/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent")
    }

    @Test("The user scope refuses root, the system scope needs it, and a dry run needs neither")
    func refusals() {
        #expect(throws: MacInstallRefusal.self) {
            try MacInstallLayout.layout(
                for: .user, dryRun: false, effectiveUID: 0, home: "/var/root", consoleUserID: 501)
        }
        #expect(throws: MacInstallRefusal.self) {
            try MacInstallLayout.layout(
                for: .system, dryRun: false, effectiveUID: 501, home: "/Users/a", consoleUserID: 501)
        }
        #expect(
            (try? MacInstallLayout.layout(
                for: .system, dryRun: true, effectiveUID: 501, home: "/Users/a", consoleUserID: 501))
                == .system(consoleUserID: 501))
        #expect(
            (try? MacInstallLayout.layout(
                for: .user, dryRun: false, effectiveUID: 501, home: "/Users/pbear", consoleUserID: nil))
                == Self.user)
    }

    @Test("launchctl list's listing gives a running job's process, and 0 for one stopped or missing")
    func processID() {
        let listing = "PID\tStatus\tLabel\n123\t0\tapp.kernova.macosagent\n-\t75\tapp.kernova.macosagent.system\n"
        #expect(LaunchdServiceManager.processID(of: "app.kernova.macosagent", inListing: listing) == 123)
        #expect(LaunchdServiceManager.processID(of: "app.kernova.macosagent.system", inListing: listing) == 0)
        #expect(LaunchdServiceManager.processID(of: "app.kernova.other", inListing: listing) == 0)
    }

    static func parse(_ text: String) -> [String: Any] {
        (try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)) as? [String: Any] ?? [:]
    }
}
#endif
