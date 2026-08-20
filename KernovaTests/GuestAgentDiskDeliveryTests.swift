import Foundation
import Testing

@testable import Kernova

@Suite("GuestAgentDiskDelivery Tests", .admissionGated)
struct GuestAgentDiskDeliveryTests {
    // MARK: - Helpers

    /// One row of the decision table.
    struct Case: Sendable, CustomStringConvertible {
        let lastSeen: String?
        let installedVersion: String?
        let expected: GuestAgentDiskDelivery

        init(_ lastSeen: String?, _ installedVersion: String?, _ expected: GuestAgentDiskDelivery) {
            self.lastSeen = lastSeen
            self.installedVersion = installedVersion
            self.expected = expected
        }

        var description: String {
            "reported \(lastSeen ?? "nil"), installed \(installedVersion ?? "nil") → \(expected)"
        }
    }

    private static func makeConfig(
        guestOS: VMGuestOS = .macOS,
        lastSeen: String? = nil,
        installedVersion: String? = nil
    ) -> VMConfiguration {
        var config = VMConfiguration(
            name: "Test", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        config.lastSeenGuestOSVersion = lastSeen
        if let installedVersion {
            config.installedImage = .macOSRestoreImage(version: installedVersion, build: "21A559")
        }
        return config
    }

    // MARK: - Decision table

    @Test(
        "Delivery follows the guest's version",
        arguments: [
            // No signal at all keeps the behavior every VM had before the
            // virtio path existed.
            Case(nil, nil, .usb),
            // Install record alone, on both sides of the floor.
            Case(nil, "12.0.1", .virtio),
            Case(nil, "12.2.1", .virtio),
            Case(nil, "12.3", .usb),
            Case(nil, "12.3.1", .usb),
            Case(nil, "13.0", .usb),
            // Compared as numbers, not as text: "12.10" sorts below "12.3".
            Case(nil, "12.10", .usb),
            // The agent's report outranks the install record, both directions.
            Case("12.7.6", "12.0.1", .usb),
            Case("12.0.1", "12.7.6", .virtio),
            // Localized free-form reports still read as a version.
            Case("Versión 12.2.1 (Compilación 21D62)", nil, .virtio),
            Case("Version 12.3 (Build 21E230)", nil, .usb),
            // A report that parses to nothing falls through rather than
            // erasing the install record's vote.
            Case("macOS", "12.0.1", .virtio),
            Case("", "12.0.1", .virtio),
            Case("macOS", nil, .usb),
        ])
    func deliveryFollowsGuestVersion(testCase: Case) {
        let config = Self.makeConfig(
            lastSeen: testCase.lastSeen, installedVersion: testCase.installedVersion)
        #expect(GuestAgentDiskDelivery.mode(for: config) == testCase.expected)
    }

    @Test("A Linux guest never takes the virtio path", arguments: [nil, "12.1"] as [String?])
    func linuxGuestAlwaysUSB(lastSeen: String?) {
        let config = Self.makeConfig(
            guestOS: .linux, lastSeen: lastSeen, installedVersion: "12.0.1")
        #expect(GuestAgentDiskDelivery.mode(for: config) == .usb)
    }

    // MARK: - Hostile reports

    @Test("A report carrying a command still reads as its leading version")
    func reportWithTrailingJunk() {
        #expect(GuestAgentDiskDelivery.mode(for: Self.makeConfig(lastSeen: "12.3; rm -rf /")) == .usb)
    }

    @Test("A negative report reads as its digits, below the floor")
    func negativeReport() {
        #expect(GuestAgentDiskDelivery.mode(for: Self.makeConfig(lastSeen: "-1")) == .virtio)
    }

    @Test("A report too large to be a version falls through to the install record")
    func unparsablyLargeReport() {
        let huge = String(repeating: "9", count: 10_000)
        #expect(GuestAgentDiskDelivery.mode(for: Self.makeConfig(lastSeen: huge)) == .usb)
        #expect(
            GuestAgentDiskDelivery.mode(
                for: Self.makeConfig(lastSeen: huge, installedVersion: "12.0.1")) == .virtio)
    }

    @Test("An unparsable install record leaves the version unknown")
    func unparsableInstallRecord() {
        var config = Self.makeConfig()
        config.installedImage = .macOSRestoreImage(version: "not a version", build: "21A559")
        #expect(config.effectiveGuestMacOSVersion == nil)
        #expect(GuestAgentDiskDelivery.mode(for: config) == .usb)
    }

    @Test("A Linux install record never answers for a macOS guest's version")
    func linuxInstallRecordIsNotAVersion() {
        var config = Self.makeConfig()
        config.installedImage = .linuxCatalogImage(distribution: "Ubuntu", version: "12.0.1")
        #expect(config.effectiveGuestMacOSVersion == nil)
        #expect(GuestAgentDiskDelivery.mode(for: config) == .usb)
    }

    // MARK: - Version comparison

    @Test(
        "isAtLeast compares components as numbers",
        arguments: [
            ("12.3", true),
            ("12.3.0", true),
            ("12.3.1", true),
            ("12.10", true),
            ("13.0", true),
            ("26.0", true),
            ("12.2.1", false),
            ("12.2", false),
            ("12.0.1", false),
            ("11.7.10", false),
        ])
    func isAtLeastComparesNumerically(version: String, expected: Bool) throws {
        let parsed = try #require(MacOSVersion(version))
        #expect(parsed.isAtLeast(GuestAgentDiskDelivery.usbMassStorageFloor) == expected)
    }

    @Test("A compile-time version equals the same version parsed from text")
    func compileTimeVersionMatchesParsed() {
        #expect(MacOSVersion(major: 12, minor: 3) == MacOSVersion("12.3"))
        #expect(MacOSVersion(major: 12, minor: 3) == MacOSVersion("12.3.0"))
        #expect(MacOSVersion(major: 12, minor: 3, patch: 1) == MacOSVersion("12.3.1"))
    }
}
