import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMLiveIdentities Tests", .caseScoped)
@MainActor
struct VMLiveIdentitiesTests {
    @Test("A bring-up in flight holds its identity against its twin")
    func aBringUpInFlightHoldsItsIdentity() throws {
        let preferences = makeTestPreferences()
        let identity = Data([3, 1, 4])
        let library = makeWiredLibrary(preferences: preferences)
        let first = library.registerFixture(name: "First", preferences: preferences) {
            $0.genericMachineIdentifierData = identity
        }
        let second = library.registerFixture(name: "Second", preferences: preferences) {
            $0.genericMachineIdentifierData = identity
        }

        first.activity.placeForTesting(
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped))

        // No session exists yet on either side: the operation alone is what
        // makes the first live to the second's check.
        guard
            case .refuse(.identityConflict(let conflict)) = second.activity.decide(
                .start(recovery: false), posture: .commit)
        else {
            Issue.record("the twin's start was not refused on its identity")
            return
        }
        #expect(conflict.other === first)
        #expect(conflict.reason == .machineIdentity)
        #expect(second.phase == .stopped)
        withExtendedLifetime(library) {}
    }

    /// One row of the decision: the setting, what the request brings, and
    /// whether the twin also shares the MAC address on one network.
    struct Row: Sendable, CustomTestStringConvertible {
        let allowsOverride: Bool
        let override: VMIdentityOverride
        let sharesMAC: Bool
        /// `nil` admits; otherwise the reason refused and whether it asks a
        /// way through — starting anyway, or changing the VM's network.
        let expected: (reason: ConflictReason, asks: Bool)?

        var testDescription: String {
            "setting \(allowsOverride ? "on" : "off"), \(override), MAC \(sharesMAC ? "shared" : "own")"
        }
    }

    nonisolated static let rows: [Row] = [
        Row(allowsOverride: false, override: .unavailable, sharesMAC: false, expected: (.machineIdentity, false)),
        Row(allowsOverride: false, override: .askable, sharesMAC: false, expected: (.machineIdentity, false)),
        Row(allowsOverride: false, override: .confirmed, sharesMAC: false, expected: (.machineIdentity, false)),
        Row(allowsOverride: true, override: .unavailable, sharesMAC: false, expected: (.machineIdentity, false)),
        Row(allowsOverride: true, override: .askable, sharesMAC: false, expected: (.machineIdentity, true)),
        Row(allowsOverride: true, override: .confirmed, sharesMAC: false, expected: nil),
        Row(allowsOverride: false, override: .unavailable, sharesMAC: true, expected: (.macAddress, false)),
        Row(allowsOverride: false, override: .confirmed, sharesMAC: true, expected: (.macAddress, true)),
        Row(allowsOverride: true, override: .askable, sharesMAC: true, expected: (.macAddress, true)),
        Row(allowsOverride: true, override: .confirmed, sharesMAC: true, expected: (.macAddress, true)),
        // A boot chained after the call that asked keeps the confirmation and asks nothing.
        Row(allowsOverride: true, override: .confirmed.unattended, sharesMAC: false, expected: nil),
        Row(allowsOverride: true, override: .confirmed.unattended, sharesMAC: true, expected: (.macAddress, false)),
        Row(allowsOverride: true, override: .askable.unattended, sharesMAC: false, expected: (.machineIdentity, false)),
    ]

    @Test(
        "A shared machine ID is waived only by a confirmed override the setting allows; a MAC address never, though it asks for a remedy where someone can answer",
        arguments: rows)
    func decisionTable(row: Row) {
        let preferences = makeTestPreferences()
        preferences.allowsDuplicateMachineIDOverride = row.allowsOverride
        let identity = Data([2, 7, 1, 8])
        let library = makeWiredLibrary(preferences: preferences)
        let live = library.registerFixture(
            name: "Live", phase: .running(sessionID: UUID()), preferences: preferences
        ) {
            $0.genericMachineIdentifierData = identity
            $0.networkEnabled = true
            $0.macAddress = "02:4b:4e:56:0a:01"
        }
        let twin = library.registerFixture(name: "Twin", preferences: preferences) {
            $0.genericMachineIdentifierData = identity
            $0.networkEnabled = true
            $0.macAddress = row.sharesMAC ? "02:4b:4e:56:0a:01" : "02:4b:4e:56:0a:02"
        }

        let decision = twin.activity.decide(
            .start(recovery: false), posture: .commit, identity: row.override)

        switch (decision, row.expected) {
        case (.admit, nil):
            break
        case (.refuse(.identityConflict(let conflict)), let expected?):
            #expect(conflict.other === live)
            #expect(conflict.reason == expected.reason)
            #expect(conflict.asks == expected.asks)
            #expect(conflict.configuration == twin.configuration)
        default:
            Issue.record("decided \(decision)")
        }
        withExtendedLifetime(library) {}
    }
}
