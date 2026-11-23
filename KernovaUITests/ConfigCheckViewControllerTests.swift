import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The check window's keys.
@Suite("Config check window", .caseScoped)
@MainActor
struct ConfigCheckViewControllerTests {
    private let preferences = makeTestPreferences()
    @Test("Return closes the check window; Use Defaults takes a click")
    func returnCloses() throws {
        let controller = ConfigCheckViewController(source: makeSettingsViewModel(preferences: preferences))
        controller.loadViewIfNeeded()

        #expect(try #require(findButton(titled: "Close", in: controller.view)).keyEquivalent == "\r")
        #expect(try #require(findButton(titled: "Use Defaults", in: controller.view)).keyEquivalent == "")
    }
}
