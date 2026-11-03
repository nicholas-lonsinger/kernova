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

    @Test("A drop becomes one DROP offer to the console peer, its items named as dropped, served from their files")
    func dropOffersToTheConsolePeer() async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe)
        let a = try file("a.txt", "alpha")
        let folder = scratch.url.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(instance.dropOnGuest(pasteboard([a, folder]), promises: []))

        let (_, offer) = try await sentOffer(probe)
        #expect(offer.items.map { $0.representations.map(\.name) } == [[Data("a.txt".utf8)], [Data("Photos".utf8)]])
        #expect(offer.items.map { $0.representations.map(\.storage) } == [[.file], [.folder]])
        var request = PullRequest()
        request.token = offer.token
        request.item = 0
        let owner = instance.dropService.owner
        let served = await Task.detached { owner.content(request, offer.items[0].representations[0]) }.value
        #expect(served == .success(.tree(directory: scratch.url.path, name: Array("a.txt".utf8))))
    }

    @Test("A drop with no DROP console peer is refused by the hub, and reports the files did not go")
    func noConsolePeerIsRefused() async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe, console: false)

        #expect(instance.dropService.drop(pasteboard([try file("a.txt", "a")]), promises: [], peerName: "Drop VM"))

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(instance.clipboardTransferReport.failure == .interrupted(fileCount: 1))
        #expect(probe.dropOffers.isEmpty)
    }

    @Test("A dropped promise is called in as the drop is taken, and offered under the name it gives then")
    func promiseIsCalledInAtOffer() async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe)
        let receiver = FakeFilePromiseReceiver(
            name: "IMG_0001.heic", fileType: "public.heic", contents: .file(Data("photo".utf8)), named: false)

        #expect(instance.dropOnGuest(promisePasteboard(), promises: [receiver]))
        #expect(receiver.callIns == 1)

        let (_, offer) = try await sentOffer(probe)
        let representation = try #require(offer.items.first?.representations.first)
        #expect(representation.name == Data("IMG_0001.heic".utf8))
        #expect(representation.promised)
        var request = PullRequest()
        request.token = offer.token
        let owner = instance.dropService.owner
        let served = await Task.detached { owner.content(request, representation) }.value
        guard case .success(.tree(let directory, let name)) = served else {
            Issue.record("served \(served)"); return
        }
        #expect(name == Array("IMG_0001.heic".utf8))
        #expect(try Data(contentsOf: URL(filePath: directory).appending(path: "IMG_0001.heic")) == Data("photo".utf8))
        #expect(receiver.callIns == 1)
    }

    @Test("A console move mid-drop ends the drop, reported as interrupted, and nothing is offered again")
    func consoleMoveEndsTheDrop() async throws {
        let probe = AgentHubProbe()
        let instance = try await instance(probe)
        #expect(instance.dropOnGuest(pasteboard([try file("a.txt", "a")]), promises: []))
        let (request, offer) = try await sentOffer(probe)
        probe.deliver(.itemReply(request, .offered(nil)), fromConnection: 0)

        probe.deliver(
            .peerStateChanged(PeerSessionState(console: .off, sessionID: "2", userName: "pbear")), fromConnection: 0)
        try await probe.changed.wait { probe.commands.contains(.items(.withdraw(token: offer.token))) }

        try await waitForChange { instance.clipboardTransferReport.failure != nil }
        #expect(instance.clipboardTransferReport.failure == .interrupted(fileCount: nil))
        #expect(probe.dropOffers.count == 1)
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
            .items(.offerEnded(.drop, .local, token: landed.token, .completed(remoteEndBody: Data()))),
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
