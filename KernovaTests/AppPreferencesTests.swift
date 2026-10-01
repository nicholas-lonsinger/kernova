import Testing
import Foundation
import KernovaKit
import KernovaTestSupport
@testable import Kernova

@Suite("AppPreferences", .caseScoped)
struct AppPreferencesTests {
    /// A fresh `AppPreferences` and the store behind it: the round-trip tests
    /// assert on the typed property and on the key it lands under.
    private func makePreferences() -> (prefs: AppPreferences, defaults: UserDefaults) {
        let defaults = makeTestDefaults()
        return (AppPreferences(defaults: defaults), defaults)
    }

    @Test("alwaysShowAdvancedOptions defaults to false")
    func defaultsToFalse() {
        let (prefs, _) = makePreferences()
        #expect(prefs.alwaysShowAdvancedOptions == false)
    }

    @Test("alwaysShowAdvancedOptions round-trips through UserDefaults")
    func roundTrips() {
        let (prefs, defaults) = makePreferences()
        prefs.alwaysShowAdvancedOptions = true
        #expect(prefs.alwaysShowAdvancedOptions == true)
        #expect(defaults.bool(forKey: "alwaysShowAdvancedOptions") == true)

        prefs.alwaysShowAdvancedOptions = false
        #expect(prefs.alwaysShowAdvancedOptions == false)
    }

    @Test("lastSelectedVMID defaults to nil")
    func lastSelectedVMIDDefaultsToNil() {
        let (prefs, _) = makePreferences()
        #expect(prefs.lastSelectedVMID == nil)
    }

    @Test("lastSelectedVMID round-trips through UserDefaults and clears on nil")
    func lastSelectedVMIDRoundTrips() {
        let (prefs, defaults) = makePreferences()
        let id = UUID()
        prefs.lastSelectedVMID = id
        #expect(prefs.lastSelectedVMID == id)
        #expect(defaults.string(forKey: "lastSelectedVMID") == id.uuidString)

        prefs.lastSelectedVMID = nil
        #expect(prefs.lastSelectedVMID == nil)
        #expect(defaults.string(forKey: "lastSelectedVMID") == nil)
    }

    @Test("vmOrder defaults to nil")
    func vmOrderDefaultsToNil() {
        let (prefs, _) = makePreferences()
        #expect(prefs.vmOrder == nil)
    }

    @Test("vmOrder round-trips through UserDefaults")
    func vmOrderRoundTrips() {
        let (prefs, defaults) = makePreferences()
        let order = [UUID(), UUID(), UUID()]
        prefs.vmOrder = order
        #expect(prefs.vmOrder == order)
        #expect(defaults.stringArray(forKey: "vmOrder") == order.map(\.uuidString))

        prefs.vmOrder = nil
        #expect(prefs.vmOrder == nil)
    }

    @Test("keepInMenuBarOnQuit defaults to true")
    func keepInMenuBarOnQuitDefaultsToTrue() {
        let (prefs, _) = makePreferences()
        #expect(prefs.keepInMenuBarOnQuit == true)
    }

    @Test("keepInMenuBarOnQuit round-trips through UserDefaults with inverted storage")
    func keepInMenuBarOnQuitRoundTrips() {
        let (prefs, defaults) = makePreferences()
        // Stored inverted under `quitTerminatesApp`, so the false-default key
        // yields the desired `true` default (see the property's doc comment).
        prefs.keepInMenuBarOnQuit = false
        #expect(prefs.keepInMenuBarOnQuit == false)
        #expect(defaults.bool(forKey: "quitTerminatesApp") == true)

        prefs.keepInMenuBarOnQuit = true
        #expect(prefs.keepInMenuBarOnQuit == true)
        #expect(defaults.bool(forKey: "quitTerminatesApp") == false)
    }

    @Test("blockDuplicateMachineIDBoot defaults to true")
    func blockDuplicateMachineIDBootDefaultsToTrue() {
        let (prefs, _) = makePreferences()
        #expect(prefs.blockDuplicateMachineIDBoot == true)
    }

    @Test("blockDuplicateMachineIDBoot round-trips through UserDefaults with inverted storage")
    func blockDuplicateMachineIDBootRoundTrips() {
        let (prefs, defaults) = makePreferences()
        // Stored inverted under `allowDuplicateMachineIDBoot`, so the
        // false-default key yields the desired `true` default (see the
        // property's doc comment).
        prefs.blockDuplicateMachineIDBoot = false
        #expect(prefs.blockDuplicateMachineIDBoot == false)
        #expect(defaults.bool(forKey: "allowDuplicateMachineIDBoot") == true)

        prefs.blockDuplicateMachineIDBoot = true
        #expect(prefs.blockDuplicateMachineIDBoot == true)
        #expect(defaults.bool(forKey: "allowDuplicateMachineIDBoot") == false)
    }

    @Test("cloneOutcome defaults to New Machine")
    func cloneOutcomeDefaultsToNewMachine() {
        let (prefs, _) = makePreferences()
        #expect(prefs.cloneOutcome == .newMachine)
    }

    @Test("cloneOutcome round-trips through the cloneKeepsMachineID key")
    func cloneOutcomeRoundTrips() {
        let (prefs, defaults) = makePreferences()
        prefs.cloneOutcome = .exactCopy
        #expect(prefs.cloneOutcome == .exactCopy)
        #expect(defaults.bool(forKey: "cloneKeepsMachineID") == true)

        prefs.cloneOutcome = .newMachine
        #expect(prefs.cloneOutcome == .newMachine)
        #expect(defaults.bool(forKey: "cloneKeepsMachineID") == false)
    }

    @Test("The Clone menu items name the preferred outcome first and the other as the alternate")
    func cloneMenuItemsFollowPreference() {
        let (prefs, _) = makePreferences()
        let byDefault = prefs.cloneMenuItems(for: nil)
        #expect(byDefault.primary.title == "Clone as New Machine")
        #expect(byDefault.alternate?.title == "Clone as Exact Copy")

        prefs.cloneOutcome = .exactCopy
        let exact = prefs.cloneMenuItems(for: nil)
        #expect(exact.primary.title == "Clone as Exact Copy")
        #expect(exact.alternate?.title == "Clone as New Machine")
    }

    @Test("A guest running macOS 12 or earlier is offered only Clone as Exact Copy")
    func cloneMenuItemsOfAMontereyGuestOfferOnlyAnExactCopy() {
        let (prefs, _) = makePreferences()
        var monterey = VMConfiguration(name: "Monterey", guestOS: .macOS, bootMode: .macOS)
        monterey.lastSeenGuestOSVersion = "12.7.6"
        for preferred in CloneOutcome.allCases {
            prefs.cloneOutcome = preferred
            let items = prefs.cloneMenuItems(for: monterey)
            #expect(items.primary.outcome == .exactCopy)
            #expect(items.alternate == nil)
            #expect(prefs.cloneOutcome(for: monterey) == .exactCopy)
        }

        // A guest whose version nothing has vouched for, or one past 12, offers both.
        var unknown = monterey
        unknown.lastSeenGuestOSVersion = nil
        var ventura = monterey
        ventura.lastSeenGuestOSVersion = "13.0"
        prefs.cloneOutcome = .newMachine
        for configuration in [unknown, ventura] {
            let items = prefs.cloneMenuItems(for: configuration)
            #expect(items.primary.outcome == .newMachine)
            #expect(items.alternate?.outcome == .exactCopy)
        }
    }

    @Test("menuBarQuitReminderDismissed defaults to false")
    func menuBarQuitReminderDismissedDefaultsToFalse() {
        let (prefs, _) = makePreferences()
        #expect(prefs.menuBarQuitReminderDismissed == false)
    }

    @Test("menuBarQuitReminderDismissed round-trips through UserDefaults")
    func menuBarQuitReminderDismissedRoundTrips() {
        let (prefs, defaults) = makePreferences()
        prefs.menuBarQuitReminderDismissed = true
        #expect(prefs.menuBarQuitReminderDismissed == true)
        #expect(defaults.bool(forKey: "menuBarQuitReminderDismissed") == true)

        prefs.menuBarQuitReminderDismissed = false
        #expect(prefs.menuBarQuitReminderDismissed == false)
    }

    @Test("mainToolbarNewVMCollapseIndex defaults to nil")
    func mainToolbarNewVMCollapseIndexDefaultsToNil() {
        let (prefs, _) = makePreferences()
        #expect(prefs.mainToolbarNewVMCollapseIndex == nil)
    }

    @Test("mainToolbarNewVMCollapseIndex round-trips through UserDefaults and clears on nil")
    func mainToolbarNewVMCollapseIndexRoundTrips() {
        let (prefs, defaults) = makePreferences()
        prefs.mainToolbarNewVMCollapseIndex = 2
        #expect(prefs.mainToolbarNewVMCollapseIndex == 2)
        #expect(defaults.object(forKey: "KernovaMainToolbarNewVMCollapseIndex") as? Int == 2)

        prefs.mainToolbarNewVMCollapseIndex = nil
        #expect(prefs.mainToolbarNewVMCollapseIndex == nil)
        #expect(defaults.object(forKey: "KernovaMainToolbarNewVMCollapseIndex") == nil)
    }

    @Test("mainToolbarNewVMCollapseIndex distinguishes slot 0 from an absent removal")
    func mainToolbarNewVMCollapseIndexZeroIsNotNil() {
        let (prefs, _) = makePreferences()
        // Index 0 is a real slot (New VM can be the leading item), so the
        // getter must not conflate it with "no removal recorded" the way a
        // plain `integer(forKey:)` would.
        prefs.mainToolbarNewVMCollapseIndex = 0
        #expect(prefs.mainToolbarNewVMCollapseIndex == 0)
    }

    @Test("clipboardMaxPasteBytes defaults to the derived ceiling")
    func clipboardMaxPasteBytesDefaults() {
        let (prefs, _) = makePreferences()
        #expect(prefs.clipboardMaxPasteBytes == ClipboardPasteLimit.defaultBytes)
    }

    @Test("clipboardMaxPasteBytes round-trips every offered ceiling through UserDefaults")
    func clipboardMaxPasteBytesRoundTrips() {
        let (prefs, defaults) = makePreferences()
        for choice in ClipboardPasteLimit.choices {
            prefs.clipboardMaxPasteBytes = choice
            #expect(prefs.clipboardMaxPasteBytes == choice)
            #expect(defaults.object(forKey: "clipboardMaxPasteBytes") as? Int == choice)
        }
    }

    @Test("a stored ceiling off the offered ladder reads back as the nearest one")
    func clipboardMaxPasteBytesClampsOnRead() {
        let (prefs, defaults) = makePreferences()
        // Nothing writes this through the setter — a hand-edited default, or
        // a value from a build whose ladder differed. It must never reach an
        // enforcement point as-is.
        defaults.set(3 * 1024 * 1024 * 1024, forKey: "clipboardMaxPasteBytes")
        #expect(ClipboardPasteLimit.choices.contains(prefs.clipboardMaxPasteBytes))
    }

    @Test("resetHostReminders clears the host reminder flag")
    func resetHostRemindersClearsTheFlag() {
        let (prefs, _) = makePreferences()
        prefs.menuBarQuitReminderDismissed = true

        prefs.resetHostReminders()

        #expect(prefs.menuBarQuitReminderDismissed == false)
    }

    @Test("resetHostReminders is a no-op on fresh defaults")
    func resetHostRemindersIdempotentOnFreshDefaults() {
        let (prefs, _) = makePreferences()
        prefs.resetHostReminders()

        #expect(prefs.menuBarQuitReminderDismissed == false)
    }
}
