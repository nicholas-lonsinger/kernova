import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("GuestAgentDiskDelivery Tests", .caseScoped)
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
            name: "Test",
            guestOS: guestOS,
            bootMode: guestOS == .macOS ? .macOS : .efi,
            cpuCount: guestOS.hostCPUCount,
            memorySizeInGB: guestOS.hostMemorySize)
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

    // MARK: - Hostile reports

    @Test("A report too large to be a version falls through to the install record")
    func unparsablyLargeReport() {
        let huge = String(repeating: "9", count: 10_000)
        #expect(GuestAgentDiskDelivery.mode(for: Self.makeConfig(lastSeen: huge)) == .usb)
        #expect(
            GuestAgentDiskDelivery.mode(
                for: Self.makeConfig(lastSeen: huge, installedVersion: "12.0.1")) == .virtio)
    }
}
