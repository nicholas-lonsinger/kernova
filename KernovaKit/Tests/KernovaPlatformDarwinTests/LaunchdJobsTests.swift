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

    @Test(
        "\"For everyone\" asked for by a user stops and removes that user's \"Just for me\" jobs once its own are loaded"
    )
    func systemPlanReplacesUserJobs() {
        let plain = InstallPlan.install(Self.system, stopTool: Self.tool)
        let plan = InstallPlan.install(Self.system, stopTool: Self.tool, replacing: Self.user)
        #expect(plan.before == plain.before && plan.treeWrites == plain.treeWrites && plan.writes == plain.writes)
        #expect(
            plan.removals == [
                "/Users/pbear/Library/LaunchAgents/app.kernova.macosagent.plist",
                "/Users/pbear/Library/LaunchAgents/app.kernova.macosagent.rollback.plist",
            ])
        #expect(
            plan.after == plain.after + [
                InstallPlan.Command([Self.tool, "stop-service", "gui/501/app.kernova.macosagent.rollback"]),
                InstallPlan.Command([Self.tool, "stop-service", "gui/501/app.kernova.macosagent"]),
            ])
        // The user's own root stays.
        #expect(!plan.removesRoot && plan.treeRemovals.allSatisfy { $0.hasPrefix(Self.systemRoot + "/") })
    }

    @Test("With no user at the console, \"For everyone\" leaves the session agent to the next login")
    func systemPlanWithoutConsoleUser() {
        let plan = InstallPlan.install(MacInstallLayout.system(consoleUserID: nil), stopTool: Self.tool)
        #expect(!plan.steps.map(\.description).contains { $0.contains("gui/") })
        #expect(
            plan.writes.contains(
                .file(
                    path: "/Library/LaunchAgents/app.kernova.macosagent.session.plist", mode: 0o644,
                    text: LaunchdPlists.session(.system(consoleUserID: nil)))))
    }

    @Test("An uninstall stops every job, then removes every property list and the root")
    func uninstallPlans() {
        let user = InstallPlan.uninstall(Self.user, stopTool: Self.tool)
        #expect(user.before == InstallPlan.install(Self.user, stopTool: Self.tool).before)
        #expect(
            user.removals == [
                "/Users/pbear/Library/LaunchAgents/app.kernova.macosagent.plist",
                "/Users/pbear/Library/LaunchAgents/app.kernova.macosagent.rollback.plist",
            ])
        #expect(user.removesRoot && user.after.isEmpty)
        let system = InstallPlan.uninstall(Self.system, stopTool: Self.tool)
        #expect(
            system.removals == [
                "/Library/LaunchAgents/app.kernova.macosagent.session.plist",
                "/Library/LaunchDaemons/app.kernova.macosagent.system.plist",
                "/Library/LaunchDaemons/app.kernova.macosagent.system.rollback.plist",
            ])
    }

    @Test("The user scope's refresh rewrites exactly its property lists and runs nothing")
    func refresh() {
        let plan = InstallPlan.refreshJobs(Self.user)
        #expect(plan.writes == InstallPlan.install(Self.user, stopTool: Self.tool).writes)
        #expect(plan.before.isEmpty && plan.after.isEmpty && plan.treeWrites.isEmpty && !plan.removesRoot)
    }

    @Test("The session peer's LaunchAgent runs the agent through current, in Aqua, kept alive only on failure")
    func sessionPlist() {
        #expect(
            LaunchdPlists.session(Self.user) == """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                \t<key>Label</key>
                \t<string>app.kernova.macosagent</string>
                \t<key>AssociatedBundleIdentifiers</key>
                \t<array>
                \t\t<string>app.kernova.macosagent</string>
                \t</array>
                \t<key>ProgramArguments</key>
                \t<array>
                \t\t<string>\(Self.userRoot)/current/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent</string>
                \t\t<string>session</string>
                \t</array>
                \t<key>RunAtLoad</key>
                \t<true/>
                \t<key>KeepAlive</key>
                \t<dict>
                \t\t<key>SuccessfulExit</key>
                \t\t<false/>
                \t</dict>
                \t<key>LimitLoadToSessionType</key>
                \t<string>Aqua</string>
                </dict>
                </plist>

                """)
        #expect(Self.parse(LaunchdPlists.session(Self.system))["Label"] as? String == "app.kernova.macosagent.session")
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

    @Test(
        "Every property list, in both scopes, names the agent's bundle and runs the agent's own executable",
        arguments: [true, false])
    func attributedToTheAgent(_ system: Bool) {
        let layout = system ? Self.system : Self.user
        let texts = InstallPlan.install(layout, stopTool: Self.tool).writes.compactMap { write -> String? in
            if case .file(_, _, let text) = write { text } else { nil }
        }
        #expect(texts.count == (system ? 3 : 2))
        for text in texts {
            let plist = Self.parse(text)
            #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["app.kernova.macosagent"])
            #expect(
                (plist["ProgramArguments"] as? [String])?.first?.hasSuffix(
                    "/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent") == true)
        }
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

    @Test("The rollback check kills the job that pulls and switches: the session peer, or the system peer")
    func updatingJobs() {
        #expect(Self.user.updatingLabel == "app.kernova.macosagent")
        #expect(Self.system.updatingLabel == "app.kernova.macosagent.system")
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
