import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// ``VMLibraryViewModel/vmNamesSharingMachineIdentity(with:)``: which other VMs
/// the General section names as holding a VM's machine ID.
@Suite("VM Machine Identity Holders Tests", .caseScoped)
@MainActor
struct VMMachineIdentityHoldersTests {
    private let viewModel = makeSettingsViewModel(preferences: makeTestPreferences())

    @Test("Every other VM holding the identity is named, in library order")
    func holdersAreNamedInLibraryOrder() {
        let identity = Data([1, 4, 1, 4])
        viewModel.library.admitFixture(name: "First") { $0.genericMachineIdentifierData = identity }
        let instance = viewModel.library.admitFixture(name: "Mine") {
            $0.genericMachineIdentifierData = identity
        }
        viewModel.library.admitFixture(name: "Other") { $0.genericMachineIdentifierData = Data([9]) }
        viewModel.library.admitFixture(name: "Last") { $0.genericMachineIdentifierData = identity }

        #expect(viewModel.vmNamesSharingMachineIdentity(with: instance) == ["First", "Last"])
    }

    @Test("A VM with an identity of its own, or none at all, shares it with no one")
    func uniqueAndMissingIdentitiesShareNothing() {
        let unique = viewModel.library.admitFixture(name: "Unique") {
            $0.genericMachineIdentifierData = Data([1])
        }
        let none = viewModel.library.admitFixture(name: "None")
        viewModel.library.admitFixture(name: "Also None")

        #expect(viewModel.vmNamesSharingMachineIdentity(with: unique).isEmpty)
        #expect(viewModel.vmNamesSharingMachineIdentity(with: none).isEmpty)
    }

    @Test("Holders are named by machine ID alone, never by MAC address")
    func holdersAreIndependentOfTheMACAddress() {
        let identity = Data([2, 7, 1, 8])
        let instance = viewModel.library.admitFixture(name: "Mine") {
            $0.macAddress = "aa:bb:cc:dd:ee:01"
            $0.genericMachineIdentifierData = identity
        }
        viewModel.library.admitFixture(name: "Same ID") {
            $0.macAddress = "aa:bb:cc:dd:ee:02"
            $0.genericMachineIdentifierData = identity
        }
        viewModel.library.admitFixture(name: "Same MAC") {
            $0.macAddress = "aa:bb:cc:dd:ee:01"
            $0.genericMachineIdentifierData = Data([3, 1, 4])
        }

        #expect(viewModel.vmNamesSharingMachineIdentity(with: instance) == ["Same ID"])
    }

    @Test("A macOS identifier held only in the bundle's file is shared like one in the configuration")
    func fileOnlyMacOSIdentityIsShared() throws {
        let identity = Data([5, 5, 5])
        let instance = viewModel.library.admitFixture(name: "Mine", guestOS: .macOS) {
            $0.machineIdentifierData = identity
        }
        let fileOnly = viewModel.library.admitFixture(name: "File Only", guestOS: .macOS)
        try FileManager.default.createDirectory(at: fileOnly.bundleURL, withIntermediateDirectories: true)
        try identity.write(to: fileOnly.machineIdentifierURL)

        #expect(viewModel.vmNamesSharingMachineIdentity(with: instance) == ["File Only"])
        #expect(viewModel.vmNamesSharingMachineIdentity(with: fileOnly) == ["Mine"])
    }
}
