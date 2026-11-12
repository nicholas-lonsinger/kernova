import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What a drop onto a VM's display asks of its agent hub, seen through a probe standing in for the hub's
/// connections: the DROP offer, what serving its pulls reads, and what each way the offer ends reports.
@MainActor
@Suite("Hub drop service", .caseScoped)
struct HubDropServiceTests {
    /// The pull each served request stands for.
    nonisolated private static let pull = ItemPullID(
        generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 2))

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
        probe.deliver(.helloReceived(Self.claim, Self.onConsole), fromConnection: 0)
        probe.deliver(.featuresChanged(Self.features), fromConnection: 0)
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

    /// A pasteboard of one file promise item.
    private func promisePasteboard() -> FakePasteboard {
        let pasteboard = FakePasteboard()
        pasteboard.setFilePromise()
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

    /// An instance whose one drop of `a.txt` the console peer has opened, and that offer.
    private func openDrop(_ probe: AgentHubProbe) async throws -> (VMInstance, ItemOffer) {
        let instance = try await instance(probe)
        #expect(instance.dropOnGuest(pasteboard([try file("a.txt", "a")]), promises: []))
        let (request, offer) = try await sentOffer(probe)
        probe.deliver(.itemReply(request, .offered(nil)), fromConnection: 0)
        return (instance, offer)
    }

    @Test("The console leaving the only peer mid-drop ends the drop as no agent taking drops, offered once")
    func consoleLeavingEndsTheDrop() async throws {
        let probe = AgentHubProbe()
        let (instance, offer) = try await openDrop(probe)

        probe.deliver(
            .peerStateChanged(PeerSessionState(console: .off, sessionID: "2", userName: "pbear")), fromConnection: 0)
        try await probe.changed.wait {
            probe.commands.contains(.items(.withdraw(token: offer.token, code: .capabilityWithdrawn)))
        }

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(instance.clipboardTransferReport.failure == .dropStopped(.noAgent))
        #expect(probe.dropOffers.count == 1)
    }

    @Test("A drop moved to another session's agent mid-drop says another agent took drops over")
    func consoleMoveEndsTheDrop() async throws {
        let probe = AgentHubProbe()
        let (instance, offer) = try await openDrop(probe)

        #expect(probe.connect())
        let other = PeerClaim(
            role: .sessionPeer, scope: .user, os: .macOS, architecture: .arm64, versionLabel: "1.0 (1)",
            instanceID: Data(repeating: 2, count: 16))
        probe.deliver(
            .helloReceived(other, PeerSessionState(console: .on, sessionID: "3", userName: "other")),
            fromConnection: 1)
        probe.deliver(.featuresChanged(Self.features), fromConnection: 1)
        try await probe.changed.wait {
            probe.commands.contains(.items(.withdraw(token: offer.token, code: .capabilityWithdrawn)))
        }

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(instance.clipboardTransferReport.failure == .dropStopped(.movedToAnotherAgent))
    }

    @Test("Drops turned off in the VM's settings mid-drop end the drop as turned off")
    func policyOffEndsTheDrop() async throws {
        let probe = AgentHubProbe()
        let (instance, offer) = try await openDrop(probe)

        probe.deliver(
            .featuresChanged(
                FeatureStatusTable([
                    (FeatureID.itemTransfer, Availability<Data>.available(Data())),
                    (.drop, .absent(.disabledByPolicy, debugDetail: "")),
                ])),
            fromConnection: 0)
        try await probe.changed.wait {
            probe.commands.contains(.items(.withdraw(token: offer.token, code: .disabledByPolicy)))
        }

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(instance.clipboardTransferReport.failure == .dropStopped(.turnedOff))
    }

    @Test("A drop whose connection ends mid-drop says so, counting its files")
    func connectionLossEndsTheDrop() async throws {
        let probe = AgentHubProbe()
        let (instance, offer) = try await openDrop(probe)

        probe.deliver(.items(.offerEnded(.drop, .local, token: offer.token, .connectionLost)), fromConnection: 0)

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(instance.clipboardTransferReport.failure == .interrupted(fileCount: 1))
    }

    @Test(
        "A peer refusing the drop is worded by why it could not land it",
        arguments: [
            (WireError(.writeFailed, posixErrno: EPERM), ClipboardErrorCode.dropDownloadsDenied),
            (WireError(.writeFailed, posixErrno: EACCES), .dropDownloadsDenied),
            (WireError(.writeFailed, posixErrno: ENOSPC), .dropDiskFull),
            (WireError(.itemUnpackRefused), .dropUnpackFailed),
            (WireError(.writeFailed, posixErrno: EIO), .dropFailed),
        ])
    func refusalIsWorded(error: WireError, code: ClipboardErrorCode) async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe)
        #expect(instance.dropOnGuest(pasteboard([try file("a.txt", "a")]), promises: []))
        let (request, offer) = try await sentOffer(probe)
        probe.deliver(.itemReply(request, .offered(nil)), fromConnection: 0)

        probe.deliver(
            .items(.offerEnded(.drop, .local, token: offer.token, .resetByPeer(error))), fromConnection: 0)

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(instance.clipboardTransferReport.failure == .peerReported(code))
    }

    @Test("A drop the peer releases once landed reports nothing")
    func landedDropReportsNothing() async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe)
        var reports: [ClipboardTransferReport] = []
        let mirror = instance.clipboardTransfers.onReportChanged
        instance.clipboardTransfers.onReportChanged = { report in
            reports.append(report)
            mirror?(report)
        }
        #expect(instance.dropOnGuest(pasteboard([try file("a.txt", "a")]), promises: []))
        let (request, landed) = try await sentOffer(probe)
        probe.deliver(.itemReply(request, .offered(nil)), fromConnection: 0)
        #expect(instance.dropOnGuest(pasteboard([try file("b.txt", "b")]), promises: []))
        try await probe.changed.wait { probe.dropOffers.count == 2 }
        let (second, refused) = probe.dropOffers[1]
        probe.deliver(.itemReply(second, .offered(nil)), fromConnection: 0)

        probe.deliver(
            .items(.offerEnded(.drop, .local, token: landed.token, .completed(remoteEndBody: Self.landed([0])))),
            fromConnection: 0)
        // A later end, through the same queues, that does report: once it has, the first was handled.
        probe.deliver(
            .items(.offerEnded(.drop, .local, token: refused.token, .resetByPeer(WireError(.writeFailed)))),
            fromConnection: 0)

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(reports.compactMap(\.failure) == [.peerReported(.dropFailed)])
        #expect(instance.dropService.openOffersForTesting == 0)
    }
}

extension HubDropServiceTests {
    /// The peer's END body saying the items `items` landed.
    fileprivate static func landed(_ items: [Int]) -> Data { DropLanded(items: items).endBody }

    @Test("Every item the peer does not name as landed is reported skipped: one gone before the offer, too")
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
            .items(.offerEnded(.drop, .local, token: offer.token, .completed(remoteEndBody: Self.landed([0])))),
            fromConnection: 0)

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(instance.clipboardTransferReport.failure == .itemsSkipped(count: 1))
    }

    @Test(
        "A promise naming two files offers two items, each served from its own file, its staging kept until both land")
    func multiFilePromiseOffersEachFile() async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe)
        let receiver = FakeFilePromiseReceiver(
            files: [("a.txt", .file(Data("alpha".utf8))), ("b.txt", .file(Data("beta".utf8)))],
            fileType: "public.plain-text", deferred: true)

        #expect(instance.dropOnGuest(promisePasteboard(), promises: [receiver]))
        let (request, offer) = try await sentOffer(probe)
        #expect(offer.items.map { $0.representations.map(\.name) } == [[Data("a.txt".utf8)], [Data("b.txt".utf8)]])
        probe.deliver(.itemReply(request, .offered(nil)), fromConnection: 0)

        receiver.deliver(1)
        var pull = PullRequest()
        pull.token = offer.token
        pull.item = 1
        let second = pull
        let owner = instance.dropService.owner
        let representation = offer.items[1].representations[0]
        let served = await Task.detached { owner.content(Self.pull, second, representation) }.value
        guard case .success(.tree(let path)) = served else {
            Issue.record("served \(served)"); return
        }
        #expect(try Data(contentsOf: URL(filePath: path)) == Data("beta".utf8))
        let staging = URL(filePath: path).deletingLastPathComponent()

        probe.deliver(
            .items(.offerEnded(.drop, .local, token: offer.token, .completed(remoteEndBody: Self.landed([1])))),
            fromConnection: 0)
        try await waitForChange { instance.clipboardTransferReport.failure == .itemsSkipped(count: 1) }
        // The first file is still owed, so its staging stays.
        #expect(FileManager.default.fileExists(atPath: staging.path))

        receiver.deliver(0)
        let release = try #require(instance.dropService.stagingReleasesForTesting.first)
        await release.value
        #expect(!FileManager.default.fileExists(atPath: staging.path))
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
