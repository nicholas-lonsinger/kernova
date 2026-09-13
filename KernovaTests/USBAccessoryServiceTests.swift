import Foundation
import Testing

@testable import Kernova

/// The part of the real service a test can reach without an `AAUSBAccessory`,
/// which has no constructible form: the wait a warm capture parks on while it
/// waits for macOS to hand an accessory back.
@Suite("USBAccessoryService Tests", .admissionGated)
@MainActor
struct USBAccessoryServiceTests {
    private let identity = USBAccessoryIdentity(key: "04e8:6300:1100:0373", form: .serialNumber)

    @Test("A wait for an accessory nothing answers to ends at its backstop")
    func aWaitForAMissingAccessoryGivesUp() async throws {
        guard #available(macOS 27.0, *) else { return }
        // Nothing is ever assigned here, so the deadline is the behavior under
        // test and a small value is the correct one.
        let service = USBAccessoryService(registry: MockUSBAccessoryRegistry())

        let found = await service.accessory(matching: identity, appearingWithin: .milliseconds(20))

        #expect(found == nil)
    }
}
