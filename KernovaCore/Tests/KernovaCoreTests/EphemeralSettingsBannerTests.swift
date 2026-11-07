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

    @Test("The banner shows only with a baseline and the reminder on, and never on the overview")
    func baselineAndReminderDecideTheBanner() {
        #expect(
            EphemeralSettingsBanner(category: .network, baseline: baseline, dismissed: false)
                == EphemeralSettingsBanner(category: .network, baseline: baseline, dismissed: false))
        #expect(
            EphemeralSettingsBanner(category: .network, baseline: baseline, dismissed: false)?.baselineName
                == "Clean install")
        #expect(EphemeralSettingsBanner(category: .network, baseline: nil, dismissed: false) == nil)
        #expect(EphemeralSettingsBanner(category: .network, baseline: baseline, dismissed: true) == nil)
        #expect(EphemeralSettingsBanner(category: nil, baseline: baseline, dismissed: false) == nil)
    }

    @Test("A VM's baseline is there only while the mode is on and the snapshot it names is listed")
    func baselineFollowsModeAndManifest() {
        let wired = WiredCommandCore()
        let on = wired.register(
            name: "On", snapshots: [baseline], hostState: .ephemeral(baseline: baseline.id))
        var offState = VMHostState.ephemeral(baseline: baseline.id)
        offState.ephemeralModeEnabled = false
        let off = wired.register(name: "Off", snapshots: [baseline], hostState: offState)
        let missing = wired.register(name: "Missing", hostState: .ephemeral(baseline: baseline.id))

        for (instance, shows) in [(on, true), (off, false), (missing, false)] {
            let banner = EphemeralSettingsBanner(
                category: .system, baseline: instance.ephemeralBaselineSnapshot, dismissed: false)
            #expect((banner != nil) == shows)
        }
    }

    @Test("A move of a setting the snapshot holds is one a revert undoes; identity is not")
    func revertRestoresEverythingButIdentity() {
        let held = VMInstanceFixture.makeConfiguration(name: "Held", guestOS: .linux)
        var settings = held
        settings.cpuCount += 1
        #expect(held.movesFieldARevertRestores(to: settings))

        var renamed = held
        renamed.name = "Renamed"
        renamed.createdAt = held.createdAt.addingTimeInterval(60)
        #expect(!held.movesFieldARevertRestores(to: renamed))
        #expect(!held.movesFieldARevertRestores(to: held))
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
