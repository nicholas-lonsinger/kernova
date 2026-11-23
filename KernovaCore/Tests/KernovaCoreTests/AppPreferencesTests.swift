import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("AppPreferences", .caseScoped)
struct AppPreferencesTests {
    /// A fresh `AppPreferences` and the store behind it: the round-trip tests
    /// assert on the typed property and on the key it lands under.
    private func makePreferences() -> (prefs: AppPreferences, defaults: UserDefaults) {
        let defaults = makeTestDefaults()
        return (AppPreferences(defaults: defaults), defaults)
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

    @Test("allowsDuplicateMachineIDOverride reads and writes the allowDuplicateMachineIDBoot key as stored")
    func allowsDuplicateMachineIDOverrideRoundTrips() {
        let (prefs, defaults) = makePreferences()
        // A value an earlier build stored under the key carries over as it is.
        defaults.set(true, forKey: "allowDuplicateMachineIDBoot")
        #expect(prefs.allowsDuplicateMachineIDOverride == true)

        prefs.allowsDuplicateMachineIDOverride = false
        #expect(defaults.bool(forKey: "allowDuplicateMachineIDBoot") == false)
        prefs.allowsDuplicateMachineIDOverride = true
        #expect(defaults.bool(forKey: "allowDuplicateMachineIDBoot") == true)
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

    @Test("clipboardMaxPasteBytes round-trips every offered ceiling through UserDefaults")
    func clipboardMaxPasteBytesRoundTrips() {
        let (prefs, defaults) = makePreferences()
        for choice in ClipboardPasteLimit.choices {
            prefs.clipboardMaxPasteBytes = choice
            #expect(prefs.clipboardMaxPasteBytes == choice)
            #expect(defaults.object(forKey: "clipboardMaxPasteBytes") as? Int == choice)
        }
    }

    @Test("Every reserved shortcut is on until one is turned off, and the switches round-trip")
    func reservedShortcutsRoundTrip() {
        let (prefs, defaults) = makePreferences()
        #expect(prefs.disabledReservedShortcuts.isEmpty)

        prefs.disabledReservedShortcuts = [.copyMacClipboardToGuest]
        #expect(prefs.disabledReservedShortcuts == [.copyMacClipboardToGuest])
        #expect(defaults.stringArray(forKey: "disabledReservedShortcuts") == ["copyMacClipboardToGuest"])
        // A second preferences object over the same store is the next launch.
        #expect(AppPreferences(defaults: defaults).disabledReservedShortcuts == [.copyMacClipboardToGuest])

        prefs.disabledReservedShortcuts = []
        #expect(AppPreferences(defaults: defaults).disabledReservedShortcuts.isEmpty)
    }

    @Test("A stored shortcut name no case carries is dropped on read")
    func reservedShortcutsDropUnknownNames() {
        let (prefs, defaults) = makePreferences()
        defaults.set(["copyGuestClipboardToMac", "noSuchShortcut"], forKey: "disabledReservedShortcuts")
        #expect(prefs.disabledReservedShortcuts == [.copyGuestClipboardToMac])
    }
}
