import Foundation
import Testing

@testable import Kernova

@Suite("GuestInputDevices Tests")
struct GuestInputDevicesTests {
    // MARK: - Helpers

    /// One row of the decision table.
    struct Case: Sendable, CustomStringConvertible {
        let lastSeen: String?
        let installedVersion: String?
        let expected: GuestInputDevices

        init(_ lastSeen: String?, _ installedVersion: String?, _ expected: GuestInputDevices) {
            self.lastSeen = lastSeen
            self.installedVersion = installedVersion
            self.expected = expected
        }

        var description: String {
            "reported \(lastSeen ?? "nil"), installed \(installedVersion ?? "nil") → \(expected)"
        }
    }

    private static func makeConfig(
        lastSeen: String? = nil,
        installedVersion: String? = nil,
        mode: VMInputDeviceMode = .automatic
    ) -> VMConfiguration {
        var config = VMConfiguration(name: "Test", guestOS: .macOS, bootMode: .macOS)
        config.lastSeenGuestOSVersion = lastSeen
        config.inputDeviceMode = mode
        if let installedVersion {
            config.installedImage = .macOSRestoreImage(version: installedVersion, build: "21A559")
        }
        return config
    }

    // MARK: - Automatic decision table

    @Test(
        "Automatic resolves the pair from the guest's version",
        arguments: [
            // No signal at all resolves to the Mac pair — still exactly one.
            Case(nil, nil, .mac),
            // Install record alone, on both sides of the floor.
            Case(nil, "12.7.6", .usb),
            Case(nil, "12.9.9", .usb),
            Case(nil, "13.0", .mac),
            Case(nil, "13.0.1", .mac),
            Case(nil, "26.0", .mac),
            // The agent's report outranks the install record, both directions.
            Case("13.5", "12.0.1", .mac),
            Case("12.0.1", "13.5", .usb),
            // Localized free-form reports still read as a version.
            Case("Versión 12.2.1 (Compilación 21D62)", nil, .usb),
            Case("Version 13.0 (Build 22A380)", nil, .mac),
            // A report that parses to nothing falls through rather than
            // erasing the install record's vote.
            Case("macOS", "13.0", .mac),
            Case("", "12.0.1", .usb),
            Case("macOS", nil, .mac),
        ])
    func automaticFollowsGuestVersion(testCase: Case) {
        let config = Self.makeConfig(
            lastSeen: testCase.lastSeen, installedVersion: testCase.installedVersion)
        #expect(GuestInputDevices.resolve(for: config) == testCase.expected)
    }

    @Test("A Linux install record leaves the version unknown, resolving to the Mac pair")
    func linuxInstallRecordResolvesMac() {
        var config = Self.makeConfig()
        config.installedImage = .linuxCatalogImage(distribution: "Ubuntu", version: "22.04")
        #expect(GuestInputDevices.resolve(for: config) == .mac)
    }

    // MARK: - Explicit modes

    @Test("An explicit Mac choice wins over a pre-13 version")
    func explicitMacBeatsOldVersion() {
        let config = Self.makeConfig(lastSeen: "12.0.1", mode: .mac)
        #expect(GuestInputDevices.resolve(for: config) == .mac)
    }

    @Test("An explicit USB choice wins over a 13+ version")
    func explicitUSBBeatsModernVersion() {
        let config = Self.makeConfig(lastSeen: "26.0", mode: .usb)
        #expect(GuestInputDevices.resolve(for: config) == .usb)
    }
}
