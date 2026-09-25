import AppKit
import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// What the tool resolves as the app to start, how it asks for it, and how long
/// it waits for it — all decided without driving `NSWorkspace`, which no test
/// does.
@Suite("CLI app launch", .admissionGated)
struct CLIAppLaunchTests {
    private func locate(_ path: String) -> String? {
        EnclosingAppBundle.locate(executable: URL(fileURLWithPath: path))?.path
    }

    // MARK: - Enclosing bundle

    @Test("The bundled tool resolves the app it is embedded in")
    func installedToolResolvesItsApp() {
        #expect(
            locate("/Applications/Kernova.app/Contents/Helpers/kernova")
                == "/Applications/Kernova.app")
    }

    @Test("A nested bundle resolves to the innermost app enclosing the tool")
    func nestedBundleResolvesInnermost() {
        #expect(
            locate("/Applications/Outer.app/Contents/Library/Inner.app/Contents/MacOS/kernova")
                == "/Applications/Outer.app/Contents/Library/Inner.app")
    }

    @Test("A tool outside any app resolves nothing, rather than guessing")
    func looseToolResolvesNothing() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(locate(scratch.appendingPathComponent("bin/kernova").path) == nil)
        #expect(locate("/kernova") == nil)
    }

    /// The shape Settings → Advanced installs: a link on `PATH` pointing into
    /// the bundle. `Bundle.main.executableURL` answers the path the tool was
    /// invoked through, so without resolving it the installed tool finds no app
    /// to start.
    @Test("The installed tool resolves through its symlink into the app it links at")
    func installedSymlinkResolvesItsApp() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let installed = try InstalledToolFixture(in: scratch)

        let located = try #require(EnclosingAppBundle.locate(executable: installed.link))

        #expect(located.path == installed.bundle.resolvingSymlinksInPath().path)
    }

    /// An executable is a file, so its own name says nothing about a bundle to
    /// launch — only an ancestor directory can be one.
    @Test("A tool whose own name ends in .app is not itself the bundle")
    func executableLeafIsNotTheBundle() {
        #expect(locate("/Users/somebody/build/kernova.app") == nil)
        #expect(
            locate("/Applications/Kernova.app/Contents/Helpers/kernova.app")
                == "/Applications/Kernova.app")
    }

    // MARK: - Connect backoff

    @Test("The schedule starts at 50 ms and doubles to a half-second ceiling")
    func scheduleStartsSmallAndDoubles() {
        let delays = ConnectBackoff.delays()

        #expect(Array(delays.prefix(5)) == [0.05, 0.1, 0.2, 0.4, 0.5])
    }

    @Test("Every wait is bounded, and the whole schedule fits inside the deadline")
    func scheduleFitsItsDeadline() {
        let delays = ConnectBackoff.delays(initial: 0.05, cap: 0.5, deadline: 20)

        #expect(!delays.isEmpty)
        #expect(delays.allSatisfy { $0 <= 0.5 })
        #expect(delays.reduce(0, +) <= 20)
        // The tail is what the wait actually spends its time in, so it must
        // reach the cap rather than doubling forever.
        #expect(delays.last == 0.5)
    }

    @Test("A deadline too short for even one wait still yields a usable schedule")
    func tinyDeadlineYieldsAtMostWhatFits() {
        #expect(ConnectBackoff.delays(initial: 0.05, cap: 0.5, deadline: 0.05) == [0.05])
        #expect(ConnectBackoff.delays(initial: 0.05, cap: 0.5, deadline: 0.01).isEmpty)
    }

    // MARK: - Launch configuration

    /// An open that may reuse a running instance takes any copy sharing the
    /// bundle identifier, so this copy would never start beside another.
    @Test("The launch asks for a new process of the copy, hidden and not activated")
    func launchAsksForANewHiddenInstance() {
        let configuration = AppLaunch.configuration

        #expect(configuration.createsNewApplicationInstance)
        #expect(configuration.hides)
        #expect(!configuration.activates)
        #expect(!configuration.addsToRecentItems)
    }
}
