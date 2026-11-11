import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// When VM Settings says a category's settings go back at the next shutdown,
/// and what a revert counts as a change it undoes.
@Suite("Ephemeral settings banner", .caseScoped)
@MainActor
struct EphemeralSettingsBannerTests {
    private let baseline = VMSnapshot(name: "Clean install", macAddress: nil)

    @Test(
        "Only the categories a revert puts back show the banner",
        arguments: VMSettingsCategory.allCases)
    func categoryDecidesTheBanner(_ category: VMSettingsCategory) {
        let shows = EphemeralSettingsBanner(category: category, baseline: baseline, dismissed: false) != nil
        let reverting: Set<VMSettingsCategory> = [.system, .storage, .network, .sharing]
        #expect(shows == reverting.contains(category))
        #expect(category.revertsToEphemeralBaseline == reverting.contains(category))
    }

    @Test("The banner's info names the rows a revert keeps, when the panel has any")
    func bannerInfoNamesKeptRows() {
        let none = EphemeralModeCopy.settingsBannerParagraphs(baseline: "Clean install", keptRows: [])
        #expect(none.count == 1)
        guard case .body(let reverts) = none.first else {
            Issue.record("expected a body paragraph")
            return
        }
        #expect(reverts.contains("\u{201C}Clean install\u{201D}"))

        let one = EphemeralModeCopy.settingsBannerParagraphs(
            baseline: "Clean install", keptRows: ["Show install reminder"])
        #expect(one.last == .body("Show install reminder stays as you set it."))

        let two = EphemeralModeCopy.settingsBannerParagraphs(
            baseline: "Clean install", keptRows: ["Show install reminder", "Remembered USB Accessories"])
        #expect(two.last == .body("Show install reminder and Remembered USB Accessories stay as you set them."))
    }
}
