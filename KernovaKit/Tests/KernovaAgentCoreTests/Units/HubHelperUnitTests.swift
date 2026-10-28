#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire
import Testing

extension CoreUnits {
    @Suite("PowerRouting: §6.4 candidates and routing")
    struct PowerRoutingUnitTests {
        static func session(
            _ handle: UInt64, _ sessionID: String, console: ConsoleState = .on, order: UInt64? = nil,
            usable: Bool = true, actions: [PowerAction] = [.shutdown, .restart]
        ) -> RoutingPeer {
            RoutingPeer(
                handle: PeerHandle(rawValue: handle), role: .sessionPeer,
                state: PeerSessionState(console: console, sessionID: sessionID), connectedOrder: order ?? handle,
                powerUsable: usable, actions: actions)
        }

        static func system(
            _ handle: UInt64, console: ConsoleState = .on, consoleSessionID: String = "", usable: Bool = true,
            actions: [PowerAction] = [.shutdown, .restart]
        ) -> RoutingPeer {
            RoutingPeer(
                handle: PeerHandle(rawValue: handle), role: .systemPeer,
                state: PeerSessionState(console: console, consoleSessionID: consoleSessionID),
                connectedOrder: handle, powerUsable: usable, actions: actions)
        }

        static func handles(_ raw: [UInt64]) -> [PeerHandle] {
            raw.map { PeerHandle(rawValue: $0) }
        }

        static func outputs(_ routing: inout PowerRouting) -> [RoutingOutput] {
            var outputs: [RoutingOutput] = []
            while let output = routing.pollOutput() { outputs.append(output) }
            return outputs
        }

        // MARK: Candidates

        @Test("With no system peer: the session peers reporting CONSOLE_ON, newest first; nothing else")
        func noSystemPeer() {
            let peers = [
                Self.session(1, "a", order: 5), Self.session(2, "b", order: 9), Self.session(3, "c", console: .off),
                Self.session(4, "d", console: .unknown),
            ]
            #expect(PowerRouting.candidates(for: .shutdown, peers: peers, excluding: []) == Self.handles([2, 1]))
        }

        @Test("A system peer is the console authority: CONSOLE_ON names the session; then the system peer")
        func systemPeerConsoleOn() {
            let peers = [
                Self.session(1, "a"), Self.session(2, "b", console: .off), Self.session(3, "c"),
                Self.system(9, consoleSessionID: "b"),
            ]
            #expect(PowerRouting.candidates(for: .shutdown, peers: peers, excluding: []) == Self.handles([2, 9]))
        }

        @Test("A system peer reporting console UNSPECIFIED has no authority: the session peers' own reports decide")
        func systemPeerConsoleUnknown() {
            let peers = [
                Self.session(1, "a"), Self.session(2, "b", console: .off), Self.system(9, console: .unknown),
            ]
            #expect(PowerRouting.candidates(for: .shutdown, peers: peers, excluding: []) == Self.handles([1, 9]))
        }

        @Test("A system peer reporting CONSOLE_OFF makes no session peer a console candidate")
        func systemPeerConsoleOff() {
            let peers = [Self.session(1, "a"), Self.system(9, console: .off, consoleSessionID: "a")]
            #expect(PowerRouting.candidates(for: .shutdown, peers: peers, excluding: []) == Self.handles([9]))
        }

        @Test("A system peer without POWER still decides the console, but is no candidate itself")
        func systemPeerUnusableStillAuthority() {
            let peers = [
                Self.session(1, "a"), Self.session(2, "b"), Self.system(9, consoleSessionID: "b", usable: false),
            ]
            #expect(PowerRouting.candidates(for: .shutdown, peers: peers, excluding: []) == Self.handles([2]))
        }

        @Test("Two session peers of the console session go newest connection first")
        func consoleSessionNewestFirst() {
            let peers = [
                Self.session(1, "a", order: 3), Self.session(2, "a", order: 7), Self.system(9, consoleSessionID: "a"),
            ]
            #expect(PowerRouting.candidates(for: .shutdown, peers: peers, excluding: []) == Self.handles([2, 1, 9]))
        }

        @Test("A peer is a candidate only while POWER is usable, the action is offered, and it was not asked")
        func eligibility() {
            let peers = [
                Self.session(1, "a", usable: false), Self.session(2, "a", actions: [.shutdown]), Self.session(3, "a"),
                Self.session(4, "a"),
            ]
            #expect(
                PowerRouting.candidates(for: .restart, peers: peers, excluding: Self.handles([4])) == Self.handles([3]))
        }

        // MARK: Routing

        @Test("refused → recompute and ask the next; every peer refused → .acpi with the refusals")
        func refusedToAcpi() {
            let peers = [Self.session(1, "a"), Self.system(9, consoleSessionID: "a")]
            var routing = PowerRouting()
            routing.begin(.shutdown, peers: peers)
            #expect(Self.outputs(&routing) == [.ask(PeerHandle(rawValue: 1), .shutdown)])
            let first = WireError(.powerNotOnConsole)
            routing.handle(.refused(first), from: PeerHandle(rawValue: 1), peers: peers)
            #expect(Self.outputs(&routing) == [.ask(PeerHandle(rawValue: 9), .shutdown)])
            let second = WireError(.timeout)
            routing.handle(.refused(second), from: PeerHandle(rawValue: 9), peers: peers)
            #expect(
                Self.outputs(&routing) == [
                    .acpi(
                        .shutdown,
                        refusals: [
                            PeerRefusal(peer: PeerHandle(rawValue: 1), error: first),
                            PeerRefusal(peer: PeerHandle(rawValue: 9), error: second),
                        ])
                ])
            #expect(!routing.isRouting)
        }

        @Test("No candidate at all → .acpi at once with no refusals")
        func noCandidates() {
            var routing = PowerRouting()
            routing.begin(.restart, peers: [])
            #expect(Self.outputs(&routing) == [.acpi(.restart, refusals: [])])
        }

        @Test("Candidates are recomputed after each refusal from the current peer views")
        func recomputedAfterRefusal() {
            var peers = [Self.session(1, "a")]
            var routing = PowerRouting()
            routing.begin(.shutdown, peers: peers)
            _ = Self.outputs(&routing)
            peers.append(Self.session(2, "b"))
            routing.handle(.refused(WireError(.timeout)), from: PeerHandle(rawValue: 1), peers: peers)
            #expect(Self.outputs(&routing) == [.ask(PeerHandle(rawValue: 2), .shutdown)])
        }

        @Test("accepted → no other provider is asked; progress and the final result are reported")
        func acceptedThenFinished() {
            let peers = [Self.session(1, "a"), Self.system(9, consoleSessionID: "a")]
            let peer = PeerHandle(rawValue: 1)
            var routing = PowerRouting()
            routing.begin(.shutdown, peers: peers)
            _ = Self.outputs(&routing)
            routing.handle(.accepted, from: peer, peers: peers)
            routing.handle(.progress(.waitingOnApps, [AppValue(displayName: "Editor")]), from: peer, peers: peers)
            routing.handle(.finished(.blocked([AppValue(displayName: "Editor")])), from: peer, peers: peers)
            #expect(
                Self.outputs(&routing) == [
                    .progress(peer, .waitingOnApps, [AppValue(displayName: "Editor")]),
                    .blocked(peer, [AppValue(displayName: "Editor")]),
                ])
            #expect(!routing.isRouting)
        }

        @Test("Each final result after acceptance maps to its routing output")
        func finishes() {
            let peer = PeerHandle(rawValue: 1)
            let peers = [Self.session(1, "a")]
            let cases: [(PowerFinish, RoutingOutput)] = [
                (.handedOff, .handedOff(peer)), (.cancelledInGuest, .cancelledInGuest(peer)),
                (.failed(WireError(.powerOsFailed)), .failed(peer, WireError(.powerOsFailed))),
            ]
            for (finish, expected) in cases {
                var routing = PowerRouting()
                routing.begin(.shutdown, peers: peers)
                _ = Self.outputs(&routing)
                routing.handle(.accepted, from: peer, peers: peers)
                routing.handle(.finished(finish), from: peer, peers: peers)
                #expect(Self.outputs(&routing) == [expected])
            }
        }

        @Test(".indeterminate and .lostAfterAcceptance end routing; ACPI is not used")
        func indeterminateEnds() {
            let peers = [Self.session(1, "a"), Self.system(9, consoleSessionID: "a")]
            let peer = PeerHandle(rawValue: 1)
            var routing = PowerRouting()
            routing.begin(.shutdown, peers: peers)
            _ = Self.outputs(&routing)
            routing.handle(.indeterminate, from: peer, peers: peers)
            #expect(Self.outputs(&routing) == [.indeterminate(peer)])
            #expect(!routing.isRouting)

            routing.begin(.shutdown, peers: peers)
            _ = Self.outputs(&routing)
            routing.handle(.accepted, from: peer, peers: peers)
            routing.handle(.lostAfterAcceptance, from: peer, peers: peers)
            #expect(Self.outputs(&routing) == [.lostAfterAcceptance(peer)])
        }

        @Test("A second routing while one runs is .busy; a result from a peer not asked is ignored")
        func busyAndStrayResult() {
            let peers = [Self.session(1, "a"), Self.session(2, "b")]
            var routing = PowerRouting()
            routing.begin(.shutdown, peers: peers)
            routing.begin(.restart, peers: peers)
            #expect(Self.outputs(&routing) == [.ask(PeerHandle(rawValue: 2), .shutdown), .busy])
            routing.handle(.refused(WireError(.timeout)), from: PeerHandle(rawValue: 1), peers: peers)
            #expect(Self.outputs(&routing).isEmpty)
            #expect(routing.isRouting)
        }

        @Test("A refusal after acceptance cannot reopen routing: it ends .indeterminate")
        func refusalAfterAcceptance() {
            let peers = [Self.session(1, "a"), Self.session(2, "b")]
            let peer = PeerHandle(rawValue: 2)
            var routing = PowerRouting()
            routing.begin(.shutdown, peers: peers)
            _ = Self.outputs(&routing)
            routing.handle(.accepted, from: peer, peers: peers)
            routing.handle(.refused(WireError(.timeout)), from: peer, peers: peers)
            #expect(Self.outputs(&routing) == [.indeterminate(peer)])
        }
    }

    @Suite("PeerConflict: each row of §4.5")
    struct PeerConflictUnitTests {
        static let instanceA = Data(repeating: 0xAA, count: 16)
        static let instanceB = Data(repeating: 0xBB, count: 16)

        static func session(
            _ sessionID: String = "c1", scope: InstallScope = .user, instance: Data = instanceA,
            unresponsive: Bool = false
        ) -> ConflictParty {
            ConflictParty(
                claim: PeerClaim(role: .sessionPeer, scope: scope, instanceID: instance),
                state: PeerSessionState(sessionID: sessionID), isUnresponsive: unresponsive)
        }

        static func system(instance: Data = instanceA, unresponsive: Bool = false) -> ConflictParty {
            ConflictParty(
                claim: PeerClaim(role: .systemPeer, scope: .system, instanceID: instance), state: PeerSessionState(),
                isUnresponsive: unresponsive)
        }

        @Test("Different identity keys do not conflict: another role, or another session id")
        func noConflict() {
            #expect(PeerConflict.resolve(existing: Self.session("c1"), incoming: Self.session("c2")) == .noConflict)
            #expect(PeerConflict.resolve(existing: Self.session(), incoming: Self.system()) == .noConflict)
        }

        @Test("Row 1: the same non-empty instance id → the existing closes SUPERSEDED")
        func row1() {
            #expect(
                PeerConflict.resolve(existing: Self.session(), incoming: Self.session())
                    == .closeExisting(.superseded, retryAfter: nil))
            #expect(
                PeerConflict.resolve(existing: Self.system(), incoming: Self.system())
                    == .closeExisting(.superseded, retryAfter: nil))
        }

        @Test("Row 1 precedes row 2: the same instance with another scope still supersedes")
        func row1BeforeRow2() {
            #expect(
                PeerConflict.resolve(existing: Self.session(scope: .user), incoming: Self.session(scope: .unspecified))
                    == .closeExisting(.superseded, retryAfter: nil))
        }

        @Test("An empty instance id matches nothing")
        func emptyInstanceMatchesNothing() {
            #expect(
                PeerConflict.resolve(existing: Self.session(instance: Data()), incoming: Self.session(instance: Data()))
                    == .closeIncoming(.duplicatePeer, retryAfter: .milliseconds(20_000)))
        }

        @Test(
            "Row 2: session peers of different rank → the lower closes DUPLICATE_PEER, retry 60 s",
            arguments: [
                (InstallScope.user, InstallScope.system), (.user, .unspecified), (.system, .unspecified),
            ])
        func row2(_ higher: InstallScope, _ lower: InstallScope) {
            let sixty = CoreDuration.milliseconds(60_000)
            #expect(
                PeerConflict.resolve(
                    existing: Self.session(scope: higher),
                    incoming: Self.session(scope: lower, instance: Self.instanceB))
                    == .closeIncoming(.duplicatePeer, retryAfter: sixty))
            #expect(
                PeerConflict.resolve(
                    existing: Self.session(scope: lower, unresponsive: true),
                    incoming: Self.session(scope: higher, instance: Self.instanceB))
                    == .closeExisting(.duplicatePeer, retryAfter: sixty))
        }

        @Test("Row 2 precedes row 3: a lower-rank incoming never displaces an unresponsive higher-rank existing")
        func row2BeforeRow3() {
            #expect(
                PeerConflict.resolve(
                    existing: Self.session(scope: .user, unresponsive: true),
                    incoming: Self.session(scope: .system, instance: Self.instanceB))
                    == .closeIncoming(.duplicatePeer, retryAfter: .milliseconds(60_000)))
        }

        @Test("Row 3: same rank, the existing unresponsive → the existing closes SUPERSEDED")
        func row3() {
            #expect(
                PeerConflict.resolve(
                    existing: Self.session(unresponsive: true), incoming: Self.session(instance: Self.instanceB))
                    == .closeExisting(.superseded, retryAfter: nil))
            #expect(
                PeerConflict.resolve(
                    existing: Self.system(unresponsive: true), incoming: Self.system(instance: Self.instanceB))
                    == .closeExisting(.superseded, retryAfter: nil))
        }

        @Test("Row 4: same rank, the existing responsive → the incoming closes DUPLICATE_PEER, retry 20 s")
        func row4() {
            let twenty = CoreDuration.milliseconds(20_000)
            #expect(
                PeerConflict.resolve(existing: Self.session(), incoming: Self.session(instance: Self.instanceB))
                    == .closeIncoming(.duplicatePeer, retryAfter: twenty))
            #expect(
                PeerConflict.resolve(existing: Self.system(), incoming: Self.system(instance: Self.instanceB))
                    == .closeIncoming(.duplicatePeer, retryAfter: twenty))
        }

        @Test("System peers never compare by rank: a claimed scope cannot outrank the real one")
        func systemPeersIgnoreRank() {
            var incoming = Self.system(instance: Self.instanceB)
            incoming.claim.scope = .user
            #expect(
                PeerConflict.resolve(existing: Self.system(), incoming: incoming)
                    == .closeIncoming(.duplicatePeer, retryAfter: .milliseconds(20_000)))
        }
    }

    @Suite("FeatureStatus.merge: one status per feature across a VM's peers")
    struct FeatureStatusMergeUnitTests {
        static func table(_ rows: [(FeatureID, Availability<Data>)]) -> FeatureStatusTable {
            FeatureStatusTable(rows.map { (feature: $0.0, status: $0.1) })
        }

        @Test("No peer at all → every feature absent NO_AGENT")
        func noPeers() {
            let merged = FeatureStatus.merge([])
            #expect(merged.entries.map(\.feature) == [.power, .update, .logs])
            for entry in merged.entries {
                #expect(entry.status == .absent(.noAgent, debugDetail: ""))
            }
        }

        @Test("A feature is available from the first peer offering it, in the tables' order")
        func firstAvailable() {
            let first = Self.table([(.power, .absent(.notOnConsole, debugDetail: "")), (.logs, .available(Data([1])))])
            let second = Self.table([(.power, .available(Data([2]))), (.logs, .available(Data([3])))])
            let third = Self.table([(.power, .available(Data([4])))])
            let merged = FeatureStatus.merge([first, second, third])
            #expect(merged[.power] == .available(Data([2])))
            #expect(merged[.logs] == .available(Data([1])))
        }

        @Test("With no peer offering it, the absence ranked first wins, in any table order (unlisted: NOT_IMPLEMENTED)")
        func absenceByPrecedence() {
            let system = Self.table([
                (.power, .absent(.notServedByRole, debugDetail: "")),
                (.update, .absent(.notPermitted, debugDetail: "")),
                (.logs, .absent(.notOnConsole, debugDetail: "b")),
            ])
            let session = Self.table([
                (.power, .absent(.versionMismatch, debugDetail: "")), (.logs, .absent(.notOnConsole, debugDetail: "a")),
            ])
            let other = Self.table([(.power, .absent(.disabledByPolicy, debugDetail: ""))])
            let orders = [
                [system, session, other], [system, other, session], [session, system, other],
                [session, other, system], [other, system, session], [other, session, system],
            ]
            for order in orders {
                let merged = FeatureStatus.merge(order)
                #expect(merged[.power] == .absent(.versionMismatch, debugDetail: ""))
                #expect(merged[.update] == .absent(.notPermitted, debugDetail: ""))
                #expect(merged[.logs] == .absent(.notOnConsole, debugDetail: "a"))
            }
        }

        @Test("The precedence puts update-remediable reasons first and every assigned reason in it once")
        func precedenceCovers() {
            #expect(FeatureStatus.absencePrecedence.prefix(2) == [.protocolMismatch, .versionMismatch])
            #expect(Set(FeatureStatus.absencePrecedence.map(\.rawValue)).count == FeatureStatus.absencePrecedence.count)
            for reason in AbsenceReason.allCases {
                #expect(FeatureStatus.absencePrecedence.contains(reason))
            }
        }

        @Test("The merged table is ordered by feature")
        func ordered() {
            let merged = FeatureStatus.merge([Self.table([(.logs, .available(Data())), (.power, .available(Data()))])])
            #expect(merged.entries.map(\.feature) == [.power, .update, .logs])
        }
    }
}
