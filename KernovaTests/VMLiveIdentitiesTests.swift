import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMLiveIdentities Tests", .admissionGated)
@MainActor
struct VMLiveIdentitiesTests {
    @Test("A bring-up in flight holds its identity against its twin")
    func aBringUpInFlightHoldsItsIdentity() throws {
        let preferences = makeTestPreferences()
        preferences.blockDuplicateMachineIDBoot = true
        let identity = Data([3, 1, 4])
        let first = VMInstanceFixture.make(name: "First", preferences: preferences) {
            $0.genericMachineIdentifierData = identity
        }
        let second = VMInstanceFixture.make(name: "Second", preferences: preferences) {
            $0.genericMachineIdentifierData = identity
        }
        let library = makeWiredLibrary(holding: [first, second], preferences: preferences)

        try first.beginBringUp(.starting)
        #expect(first.phase == .starting(sessionID: nil))

        // No session exists yet on either side: the phase alone is what makes
        // the first live to the second's check.
        let conflict = #expect(throws: VMIdentityConflict.self) {
            try second.beginBringUp(.starting)
        }
        #expect(conflict?.other === first)
        #expect(conflict?.reason == .machineIdentity)
        #expect(second.phase == .stopped)
        withExtendedLifetime(library) {}
    }
}
