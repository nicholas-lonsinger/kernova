import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Each hot-plug sequence docs/research/2026-10-28-vz-restore-needs-usb-ports-without-a-gap.md
/// ran, against what VZ did with the state saved after it.
@Suite("USBPortLayout", .caseScoped)
struct USBPortLayoutTests {
    private static let l = UUID()
    private static let a = UUID()
    private static let b = UUID()
    private static let c = UUID()

    /// One sequence after a boot holding `L`: the devices attached in order,
    /// the ones still attached at the save, and whether VZ restored it.
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let attached: [UUID]
        let atSave: [UUID]
        let restores: Bool
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "attach B", attached: [b], atSave: [l, b], restores: true),
        Case(name: "attach A, attach B", attached: [a, b], atSave: [l, b, a], restores: true),
        Case(name: "attach A, attach B, detach B", attached: [a, b], atSave: [l, a], restores: true),
        Case(name: "attach A, detach A", attached: [a], atSave: [l], restores: true),
        Case(name: "attach A, detach A, attach B", attached: [a, b], atSave: [l, b], restores: false),
        Case(name: "attach A, attach B, detach A", attached: [a, b], atSave: [l, b], restores: false),
        Case(name: "attach A, detach A, attach A", attached: [a, a], atSave: [l, a], restores: false),
        Case(name: "attach A, B, detach A, B, attach C", attached: [a, b, c], atSave: [l, c], restores: false),
    ]

    @Test("A saved state restores exactly when VZ restored it", arguments: cases)
    func restores(_ sequence: Case) {
        var layout = USBPortLayout(starting: [Self.l])
        for device in sequence.attached { layout.attached(device) }
        #expect(layout.devicesAboveGap(sequence.atSave).isEmpty == sequence.restores)
    }

    @Test("The devices above the first empty port are named, in port order")
    func devicesAboveTheGap() {
        var layout = USBPortLayout(starting: [Self.l])
        for device in [Self.a, Self.b, Self.c] { layout.attached(device) }
        // A removed: B and C sit above its port.
        #expect(layout.devicesAboveGap([Self.c, Self.l, Self.b]) == [Self.b, Self.c])
    }

    @Test("A device the session never attached is placed nowhere, so its state does not restore")
    func unknownDevice() {
        #expect(USBPortLayout(starting: [Self.l]).devicesAboveGap([Self.l, Self.a]) == [Self.a])
        #expect(USBPortLayout(starting: []).devicesAboveGap([]).isEmpty)
    }
}
