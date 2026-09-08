import Foundation
import KernovaKit
import Testing

/// The one rule every deadline a verb takes is held to.
@Suite("Command timeout", .admissionGated)
struct CommandTimeoutTests {
    @Test(
        "A deadline is a positive, finite number of seconds",
        arguments: [
            (0.5, true), (30, true), (0, false), (-5, false), (.infinity, false), (.nan, false),
        ] as [(TimeInterval, Bool)])
    func usableDeadlines(_ deadline: (TimeInterval, Bool)) {
        let (seconds, usable) = deadline
        #expect(CommandTimeout.isUsable(seconds) == usable)
    }
}
