import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("GuestAddressObserver Tests", .serialized, .caseScoped)
@MainActor
struct GuestAddressObserverTests {
    /// The library the observer reads through. Held by the suite because the
    /// observer's reference is weak — the real one is owned by its library.
    private let roster = StubVMInstanceRoster()

    /// The wall clock every expiry here is measured against, read when the
    /// entry is scripted: the observer reads it again at the table read, and
    /// no expiry here sits within a minute of that read.
    nonisolated private static var now: Int { Int(Date().timeIntervalSince1970) }

    private static let mac = "aa:bb:cc:dd:ee:01"

    /// Networks whose common NAT and Host Only ones stand on known subnets.
    private static func subnetted() -> ScriptedVmnetNetworks {
        let vmnet = ScriptedVmnetNetworks()
        vmnet.join(.common(.nat), on: "192.168.64.0")
        vmnet.join(.common(.hostOnly), on: "192.168.128.0")
        return vmnet
    }

    private func makeObserver(
        _ table: ScriptedARPTable = ScriptedARPTable(),
        clock: any EngineClock = GatedEngineClock(),
        canObserve: Bool = true,
        entitled: Bool = true,
        vmnet: ScriptedVmnetNetworks = Self.subnetted()
    ) -> GuestAddressObserver {
        let observer = GuestAddressObserver(
            reader: table, vmnetNetworks: vmnet.service,
            entitlements: EntitlementService(
                hasVMNetworking: entitled, hasAccessoryAccess: false,
                hasTopologyObservation: canObserve),
            clock: clock)
        observer.roster = roster
        return observer
    }

    /// A VM on `mode`, running unless `phase` says otherwise.
    private func vm(
        _ mode: VMNetworkMode = .nat, mac: String? = Self.mac,
        phase: VMLifecyclePhase = .running(sessionID: UUID()), networkEnabled: Bool = true,
        isolated: Bool = false
    ) -> VMInstance {
        VMInstanceFixture.make(phase: phase) {
            $0.networkEnabled = networkEnabled
            $0.networkMode = mode
            $0.networkMembership = isolated ? .isolated : .common
            $0.macAddress = mac
        }
    }

    private static func entry(
        _ address: String, mac: String = Self.mac, expiresIn seconds: Int = 1200
    ) -> ARPEntry {
        .scripted(address, mac: mac, expiry: now + seconds)
    }

    // MARK: - What states nothing

    @Test("Bridged is assigned by the network even where nothing is observed; everything else states nothing")
    func whereNothingIsObserved() {
        #expect(makeObserver(canObserve: false).address(for: vm(.bridged)) == .externallyAssigned)
        #expect(makeObserver().address(for: vm(networkEnabled: false)) == .unavailable)
        // NAT rides system NAT without the entitlement, which no network here
        // backs.
        #expect(makeObserver(entitled: false).address(for: vm()) == .unavailable)
        #expect(makeObserver(canObserve: false).address(for: vm()) == .unavailable)
        #expect(makeObserver().address(for: vm(mac: nil)) == .unavailable)
    }

    // MARK: - When the table is read

    @Test("Reading starts with the first running VM, repeats on the interval, and ends with the last")
    func theReadLoopFollowsTheRunningVMs() async throws {
        let clock = GatedEngineClock()
        let table = ScriptedARPTable([Self.entry("192.168.64.5")])
        let observer = makeObserver(table, clock: clock)

        observer.watch()
        #expect(observer.readTaskForTesting == nil)

        let guest = vm()
        roster.instances = [guest]
        observer.watch()
        try await clock.sleepRequested.wait { !clock.parked.isEmpty }
        #expect(table.readCount == 1)
        #expect(clock.requestedSeconds == [GuestAddressObserver.pollInterval])
        #expect(observer.address(for: guest) == .observed("192.168.64.5"))

        // One loop, however many times it is asked for.
        observer.watch()
        clock.release(clock.parked[0])
        try await clock.sleepRequested.wait { clock.requestedSeconds.count == 2 && !clock.parked.isEmpty }
        #expect(table.readCount == 2)

        roster.instances = []
        let loop = try #require(observer.readTaskForTesting)
        clock.release(clock.parked[0])
        await loop.value

        #expect(observer.readTaskForTesting == nil)
        #expect(table.readCount == 2)
        // What the loop saw goes with it: a VM running again is answered by a
        // fresh read.
        roster.instances = [guest]
        #expect(observer.address(for: guest) == .notObserved)
    }
}
