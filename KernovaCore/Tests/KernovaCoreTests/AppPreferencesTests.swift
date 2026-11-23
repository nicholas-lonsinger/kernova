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

    @Test("A stored filter's network no build spells is removed alone; every other option is kept")
    func sidebarViewOptionsDropAnUnknownNetworkAlone() throws {
        let (prefs, defaults) = makePreferences()
        defaults.set(
            Data(
                #"""
                {"sort":"name","grouping":"state","showsDetails":true,
                 "filter":{"networks":["bogus:common","none"],"guestOSes":["macOS"]}}
                """#.utf8), forKey: "KernovaSidebarViewOptions")

        #expect(
            prefs.sidebarViewOptions
                == SidebarViewOptions(
                    filter: VMLibraryFilter(
                        guestOSes: [.macOS], networks: [try #require(VMLibraryFilter.Network(rawValue: "none"))]),
                    sort: .name, grouping: .state, showsDetails: true))
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

    @Test("A guest running macOS 12 or earlier is offered only Clone as Exact Copy")
    func cloneMenuItemsOfAMontereyGuestOfferOnlyAnExactCopy() {
        let (prefs, _) = makePreferences()
        var monterey = VMConfiguration(
            name: "Monterey", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
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
