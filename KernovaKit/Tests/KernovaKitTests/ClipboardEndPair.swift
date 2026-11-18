import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaLogging
import KernovaTestSupport
import KernovaWire

@testable import KernovaKit

/// A host's ``ClipboardEnd`` and a guest's over two fake pasteboards their test alone polls, joined by a
/// ``ClipboardWire`` whose messages cross only when the test delivers them: everything either end does runs as the
/// test steps it, and ``settle()`` waits until what a step set off has run.
@MainActor
final class ClipboardEndPair {
    typealias Side = ClipboardWire.Side

    /// What a side's pasteboard holds, by the name each copy's one type carries.
    enum Holding: Equatable, CustomStringConvertible {
        case nothing
        /// A copy of this side's user's.
        case user(String)
        /// This end's promised write of the far side's offer of a copy.
        case write(String)
        /// Data this end wrote, promising nothing.
        case data

        var description: String {
            switch self {
            case .nothing: "nothing"
            case .user(let name): "user copy \(name)"
            case .write(let name): "promised write of \(name)"
            case .data: "written data"
            }
        }
    }

    let hostPasteboard = FakePasteboard(pollsOnlyWhenTold: true)
    let guestPasteboard = FakePasteboard(pollsOnlyWhenTold: true)
    let host: ClipboardEnd<ClipboardHost>
    let guest: ClipboardEnd<ClipboardGuest>
    let work = ClipboardWireWork()
    /// The connection now; nil while the ends are unlinked.
    private(set) var wire: ClipboardWire?
    /// Every event each end emitted, in order.
    private(set) var events: [Side: [ClipboardEndEvent]] = [.host: [], .guest: []]
    private var reading = 0

    private static let typePrefix = "com.kernova.test.copy."
    private static let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "ClipboardEndPair")

    /// Two ends under `gate`, each allowed to offer, under `pasteCeiling`, over a fresh connection that comes up
    /// once each side `copied` names holds that copy.
    init(
        staging: ProcessStagingRoot, gate: ClipboardOfferGate, copied: [Side: String] = [:],
        pasteCeiling: @escaping @Sendable () -> Int = { ClipboardPasteLimit.defaultBytes }
    ) {
        host = ClipboardEnd(
            pasteboard: hostPasteboard, gate: gate, stagingLabel: "pair-host", stagingRoot: staging,
            pasteCeiling: pasteCeiling, providerRegistry: LazyClipboardProviderRegistry(),
            ledger: ClipboardWriteLedger(), logger: Self.logger)
        guest = ClipboardEnd(
            pasteboard: guestPasteboard, gate: gate, stagingLabel: "pair-guest", stagingRoot: staging,
            pasteCeiling: pasteCeiling, providerRegistry: LazyClipboardProviderRegistry(),
            ledger: ClipboardWriteLedger(), logger: Self.logger)
        host.onEvent = { [weak self] in self?.heard($0, from: .host) }
        guest.onEvent = { [weak self] in self?.heard($0, from: .guest) }
        host.setMayOffer(true)
        guest.setMayOffer(true)
        for (side, name) in copied { copy(name, on: side) }
        linkUp()
    }

    func pasteboard(_ side: Side) -> FakePasteboard { side == .host ? hostPasteboard : guestPasteboard }

    // MARK: Steps

    /// `side`'s user copies the one-type item `name` names.
    func copy(_ name: String, on side: Side) {
        pasteboard(side).setItem([(type: NSPasteboard.PasteboardType(Self.typePrefix + name), data: Data(name.utf8))])
    }

    /// A tick of both pasteboards' watches, the host's first.
    func poll() {
        ClipboardPasteboardWatch.pollForTesting(hostPasteboard)
        ClipboardPasteboardWatch.pollForTesting(guestPasteboard)
    }

    func setGate(_ gate: ClipboardOfferGate, on side: Side) {
        switch side {
        case .host: host.setGate(gate)
        case .guest: guest.setGate(gate)
        }
    }

    /// A fresh connection carries the clipboard on both ends.
    func linkUp() {
        let host = host
        let guest = guest
        let wire = ClipboardWire(
            work: work,
            deliver: { [weak self] side, event, wire in self?.hand(event, to: side, from: wire) },
            // Weak: each end holds the wire through its link.
            content: { [weak host, weak guest] side, id, request in
                (side == .host ? host?.content(id, request) : guest?.content(id, request))
                    ?? .failure(WireError(.cancelled, debugDetail: "the end is gone"))
            },
            pullEnded: { [weak host, weak guest] side, id, result in
                side == .host ? host?.pullEnded(id, result) : guest?.pullEnded(id, result)
            })
        self.wire = wire
        host.setLink(wire.link(.host))
        guest.setLink(wire.link(.guest))
    }

    /// The connection ends on both ends.
    func linkDown() {
        wire?.cut()
        wire = nil
        host.setLink(nil)
        guest.setLink(nil)
    }

    /// Suspends until nothing a step set off is still to run: no read of either pasteboard in flight, and no
    /// event or completion the wire handed an end still queued.
    func settle() async throws {
        try await work.changed.wait { self.reading == 0 && self.work.isIdle }
    }

    // MARK: What the test sees

    /// What `side`'s pasteboard holds.
    func holding(_ side: Side) -> Holding {
        let board = pasteboard(side)
        let promised = board.promisedTypesByItem
        if !promised.isEmpty { return .write(Self.names(promised.flatMap { $0 })) }
        if board.dataByItem.contains(where: { !$0.isEmpty }) { return .data }
        let types = board.items.flatMap(\.types)
        return types.isEmpty ? .nothing : .user(Self.names(types))
    }

    /// The copy `offer` carries, by its name.
    static func name(of offer: [OfferedItem]) -> String {
        names(offer.flatMap(\.representations).map { NSPasteboard.PasteboardType($0.type.appleUTI ?? "") })
    }

    private static func names(_ types: [NSPasteboard.PasteboardType]) -> String {
        types.map { $0.rawValue.hasPrefix(typePrefix) ? String($0.rawValue.dropFirst(typePrefix.count)) : $0.rawValue }
            .joined(separator: "+")
    }

    private func heard(_ event: ClipboardEndEvent, from side: Side) {
        events[side, default: []].append(event)
        switch event {
        case .readBegan: reading += 1
        case .readEnded: reading -= 1
        default: break
        }
        work.changed.notify()
    }

    private func hand(_ event: ItemTransferEvent, to side: Side, from wire: ClipboardWire) {
        // A cut connection's events reach no end: each left it when the connection did.
        guard wire === self.wire else { return }
        switch side {
        case .host: host.handle(event, on: wire.link(.host))
        case .guest: guest.handle(event, on: wire.link(.guest))
        }
    }
}
