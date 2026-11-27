import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import KernovaTransferProgress
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What a drop onto a VM's display asks of its agent hub, seen through a probe standing in for the hub's
/// connections: the DROP offer, what serving its pulls reads, and what each way the offer ends reports.
@MainActor
@Suite("Hub drop service", .caseScoped)
struct HubDropServiceTests {
    private let scratch = TestScratchDirectory(prefix: "HubDropServiceTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    /// A running macOS instance whose hub's transport is `probe`, with one connection accepted through it,
    /// whose peer is DROP's console peer unless `console` is false.
    private func instance(_ probe: AgentHubProbe, console: Bool = true) async throws -> VMInstance {
        let instance = VMInstanceFixture.make(
            name: "Drop VM", guestOS: .macOS, phase: .running(sessionID: UUID()), agentConnector: probe
        ) { $0.lastSeenAgentVersion = "1.0 (1)" }
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(probe)
        try await probe.changed.wait { probe.isStarted }
        #expect(probe.connect())
        guard console else { return instance }
        probe.deliver(.role(.helloReceived(Self.claim, Self.onConsole)), fromConnection: 0)
        probe.deliver(.role(.featuresChanged(Self.features)), fromConnection: 0)
        try await waitForChange { instance.displayDropAvailability == .available }
        return instance
    }

    private static let claim = PeerClaim(
        role: .sessionPeer, scope: .user, os: .macOS, architecture: .arm64, versionLabel: "1.0 (1)",
        instanceID: Data(repeating: 1, count: 16))
    private static let onConsole = PeerSessionState(console: .on, sessionID: "2", userName: "pbear")
    /// DROP usable on the connection, as the host's endpoint merges it: the host owns no other item feature.
    private static let features = FeatureStatusTable([
        (FeatureID.itemTransfer, Availability<Data>.available(Data())), (.drop, .available(Data())),
    ])

    /// A pasteboard holding one file URL per item of `urls`.
    private func pasteboard(_ urls: [URL]) -> FakePasteboard {
        let pasteboard = FakePasteboard()
        pasteboard.setFiles(urls)
        return pasteboard
    }

    /// The first DROP offer the hub sent its connection, once it has.
    private func sentOffer(_ probe: AgentHubProbe) async throws -> (ItemRequestID, ItemOffer) {
        try await probe.changed.wait { !probe.dropOffers.isEmpty }
        return try #require(probe.dropOffers.first)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = scratch.url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}

extension HubDropServiceTests {
    /// The peer's END body saying `count` items landed.
    fileprivate static func landed(_ count: Int) -> Data { DropLanded(landed: count).endBody }

    @Test("A release's count of what landed decides what the drop reports, worked by hand for every count")
    func releaseCountDecidesTheReport() {
        let unreadable = ClipboardTransferFailure.itemsUnreadable
        let failed = ClipboardTransferFailure.peerReported(.dropFailed)
        func skipped(_ count: Int) -> ClipboardTransferFailure { .itemsSkipped(count: count) }
        // By landed count, 0 through one past the items.
        let table: [(items: Int, lost: Int, reports: [ClipboardTransferFailure?])] = [
            (0, 0, [unreadable, failed]),
            (0, 1, [unreadable, failed]),
            (0, 2, [unreadable, failed]),
            (1, 0, [unreadable, nil, failed]),
            (1, 1, [unreadable, skipped(1), failed]),
            (1, 2, [unreadable, skipped(2), failed]),
            (2, 0, [unreadable, skipped(1), nil, failed]),
            (2, 1, [unreadable, skipped(2), skipped(1), failed]),
            (2, 2, [unreadable, skipped(3), skipped(2), failed]),
            (3, 0, [unreadable, skipped(2), skipped(1), nil, failed]),
            (3, 1, [unreadable, skipped(3), skipped(2), skipped(1), failed]),
            (3, 2, [unreadable, skipped(4), skipped(3), skipped(2), failed]),
            (4, 0, [unreadable, skipped(3), skipped(2), skipped(1), nil, failed]),
            (4, 1, [unreadable, skipped(4), skipped(3), skipped(2), skipped(1), failed]),
            (4, 2, [unreadable, skipped(5), skipped(4), skipped(3), skipped(2), failed]),
        ]
        for row in table {
            #expect(row.reports.count == row.items + 2)
            for (landed, report) in row.reports.enumerated() {
                #expect(
                    HubDropService.failure(released: Self.landed(landed), items: row.items, lost: row.lost) == report,
                    "\(row.items) item(s), \(row.lost) lost, \(landed) landed")
            }
        }
        #expect(HubDropService.failure(released: Data([0xFF]), items: 1, lost: 0) == failed)
    }

    @Test(
        "A drop holds each dropped file's grant until its offer ends, however it ends, then gives it back",
        arguments: [
            StreamClosure.completed(remoteEndBody: DropLanded(landed: 1).endBody),
            .resetByPeer(WireError(.writeFailed)), .resetLocally(WireError(.cancelled)), .connectionLost,
        ])
    func dropHoldsGrantsUntilItEnds(ending: StreamClosure) async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe)
        let dropped = try file("a.txt", "a")
        let board = pasteboard([dropped])
        #expect(instance.dropOnGuest(board, promises: []))
        let (request, offer) = try await sentOffer(probe)
        probe.deliver(.itemReply(request, .offered(nil)), fromConnection: 0)
        #expect(board.sandbox.grants(of: dropped) == 1)

        probe.deliver(.items(.offerEnded(.drop, .local, token: offer.token, ending)), fromConnection: 0)

        try await board.sandbox.changed.wait { board.sandbox.grants(of: dropped) == 0 }
        #expect(board.sandbox.unheldGiveBacks.isEmpty)
        #expect(instance.dropService.openOffersForTesting == 0)
    }

    @Test("A drop the hub does not offer gives its files' grants back")
    func refusedDropGivesGrantsBack() async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe, console: false)
        let dropped = try file("a.txt", "a")
        let board = pasteboard([dropped])

        #expect(instance.dropService.drop(board, promises: [], peerName: "Drop VM"))

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        try await board.sandbox.changed.wait { board.sandbox.grants(of: dropped) == 0 }
        #expect(board.sandbox.unheldGiveBacks.isEmpty)
    }

    @Test("Every item the peer does not count as landed is reported skipped: one gone before the offer, too")
    func unlandedItemsAreSkipped() async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe)
        let unreadable = try file("secret.txt", "s")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        #expect(instance.dropOnGuest(pasteboard([try file("a.txt", "a"), unreadable]), promises: []))
        let (request, offer) = try await sentOffer(probe)
        #expect(offer.items.count == 1)
        probe.deliver(.itemReply(request, .offered(nil)), fromConnection: 0)
        probe.deliver(
            .items(.offerEnded(.drop, .local, token: offer.token, .completed(remoteEndBody: Self.landed(1)))),
            fromConnection: 0)

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(instance.clipboardTransferReport.failure == .itemsSkipped(count: 1))
    }
}

extension AgentHubProbe {
    /// Each DROP offer the hub sent, with the request it awaits the answer of.
    fileprivate var dropOffers: [(ItemRequestID, ItemOffer)] {
        commands.compactMap { command in
            guard case .items(.offer(let id, let offer, .drop)) = command else { return nil }
            return (id, offer)
        }
    }
}

extension ClipboardTransferReport {
    /// The refusal this report stands for, if it is one.
    fileprivate var failure: ClipboardTransferFailure? {
        guard case .finished(let finish) = self else { return nil }
        return finish.failure
    }
}
