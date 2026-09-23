import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("GuestAddressObserver Tests", .serialized, .admissionGated)
@MainActor
struct GuestAddressObserverTests {
    /// The library the observer reads through. Held by the suite because the
    /// observer's reference is weak — the real one is owned by its library.
    private let roster = StubVMInstanceRoster()

    /// The wall clock every expiry here is measured against.
    nonisolated private static let now = 1_790_000_000

    private static let mac = "aa:bb:cc:dd:ee:01"

    /// A provider whose Shared and Host Only networks stand on known subnets.
    private static func subnetted() -> MockVmnetNetworkProvider {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedSubnets = [.shared: .scripted("192.168.64.0"), .hostOnly: .scripted("192.168.128.0")]
        return vmnet
    }

    private func makeObserver(
        _ table: ScriptedARPTable = ScriptedARPTable(),
        clock: any EngineClock = GatedEngineClock(),
        canObserve: Bool = true,
        entitled: Bool = true
    ) -> GuestAddressObserver {
        let observer = GuestAddressObserver(
            reader: table, vmnetNetworks: Self.subnetted(), canObserve: canObserve,
            isVMNetworkingEntitled: entitled, clock: clock, now: { Self.now })
        observer.roster = roster
        return observer
    }

    /// A VM on `mode`, running unless `phase` says otherwise.
    private func vm(
        _ mode: VMNetworkMode = .shared, mac: String? = Self.mac,
        phase: VMLifecyclePhase = .running(sessionID: UUID()), networkEnabled: Bool = true
    ) -> VMInstance {
        VMInstanceFixture.make(phase: phase) {
            $0.networkEnabled = networkEnabled
            $0.networkMode = mode
            $0.macAddress = mac
        }
    }

    private static func entry(
        _ address: String, mac: String = Self.mac, expiresIn seconds: Int = 1200
    ) -> ARPEntry {
        .scripted(address, mac: mac, expiry: now + seconds)
    }

    // MARK: - What counts as the address

    @Test("A running VM's unexpired entry inside its network's subnet is its address")
    func anUnexpiredEntryIsTheAddress() async {
        let observer = makeObserver(ScriptedARPTable([Self.entry("192.168.64.5")]))
        let guest = vm()
        roster.instances = [guest]

        #expect(observer.address(for: guest) == .notObserved)
        await observer.readForTesting()

        #expect(observer.address(for: guest) == .observed("192.168.64.5"))
    }

    @Test("An expired entry, a permanent one, and one outside the subnet are not the address")
    func entriesThatDoNotCountAreIgnored() async {
        let observer = makeObserver(
            ScriptedARPTable([
                // Still listed well past its expiry, as the host's table does.
                Self.entry("192.168.64.5", expiresIn: -680),
                .scripted("192.168.64.6", mac: Self.mac, expiry: 0),
                Self.entry("192.168.4.26"),
            ]))
        let guest = vm()
        roster.instances = [guest]

        await observer.readForTesting()

        #expect(observer.address(for: guest) == .notObserved)
    }

    @Test("Of two entries for one VM, the one expiring last is the address")
    func theLatestExpiryWins() async {
        let observer = makeObserver(
            ScriptedARPTable([
                Self.entry("192.168.64.7", expiresIn: 1100),
                Self.entry("192.168.64.3", expiresIn: 100),
            ]))
        let guest = vm()
        roster.instances = [guest]

        await observer.readForTesting()

        #expect(observer.address(for: guest) == .observed("192.168.64.7"))
    }

    @Test("A MAC address matches as bytes, whatever either side's spelling")
    func macAddressesMatchAsBytes() async {
        let observer = makeObserver(ScriptedARPTable([Self.entry("192.168.64.5", mac: "aa:bb:cc:dd:ee:1")]))
        let guest = vm(mac: "AA:BB:CC:DD:EE:01")
        roster.instances = [guest]

        await observer.readForTesting()

        #expect(observer.address(for: guest) == .observed("192.168.64.5"))
    }

    @Test("Two VMs sharing a MAC on different networks are told apart by subnet")
    func macTwinsAreToldApartBySubnet() async {
        let observer = makeObserver(
            ScriptedARPTable([Self.entry("192.168.64.5"), Self.entry("192.168.128.9")]))
        let shared = vm(.shared)
        let hostOnly = vm(.hostOnly)
        roster.instances = [shared, hostOnly]

        await observer.readForTesting()

        #expect(observer.address(for: shared) == .observed("192.168.64.5"))
        #expect(observer.address(for: hostOnly) == .observed("192.168.128.9"))
    }

    // MARK: - What states nothing

    @Test("A stopped VM states nothing, whatever the table still lists")
    func aStoppedVMStatesNothing() async {
        let observer = makeObserver(ScriptedARPTable([Self.entry("192.168.64.5")]))
        let stopped = vm(phase: .stopped)
        roster.instances = [stopped]

        await observer.readForTesting()

        #expect(observer.address(for: stopped) == .unavailable)
    }

    @Test("Bridged is assigned by the network even where nothing is observed; everything else states nothing")
    func whereNothingIsObserved() {
        #expect(makeObserver(canObserve: false).address(for: vm(.bridged)) == .externallyAssigned)
        #expect(makeObserver().address(for: vm(networkEnabled: false)) == .unavailable)
        // Shared rides system NAT without the entitlement, which no network here
        // backs.
        #expect(makeObserver(entitled: false).address(for: vm()) == .unavailable)
        #expect(makeObserver(canObserve: false).address(for: vm()) == .unavailable)
        #expect(makeObserver().address(for: vm(mac: nil)) == .unavailable)
    }

    @Test("A failed read reads as not seen until a read succeeds")
    func aFailedReadReadsAsNotSeen() async {
        let table = ScriptedARPTable([Self.entry("192.168.64.5")])
        let observer = makeObserver(table)
        let guest = vm()
        roster.instances = [guest]
        await observer.readForTesting()

        table.error = ARPTableReadError(code: ENOMEM)
        await observer.readForTesting()
        #expect(observer.address(for: guest) == .notObserved)

        table.error = nil
        await observer.readForTesting()
        #expect(observer.address(for: guest) == .observed("192.168.64.5"))
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
        #expect(clock.requestedSeconds == [GuestAddressObserver.defaultPollInterval])
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

    @Test("Nothing is read where nothing can be observed")
    func nothingIsReadWithoutTheCapability() {
        let table = ScriptedARPTable()
        let observer = makeObserver(table, canObserve: false)
        roster.instances = [vm()]

        observer.watch()

        #expect(observer.readTaskForTesting == nil)
        #expect(table.readCount == 0)
    }
}
