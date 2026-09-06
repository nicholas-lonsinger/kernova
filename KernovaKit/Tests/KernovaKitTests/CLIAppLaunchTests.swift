import Foundation
import Testing

@testable import KernovaCLICore

/// What the tool resolves as the app to start, and how long it waits for it —
/// both decided without touching `NSWorkspace`, which no test drives.
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
    func looseToolResolvesNothing() {
        #expect(locate("/usr/local/bin/kernova") == nil)
        #expect(locate("/kernova") == nil)
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
}
