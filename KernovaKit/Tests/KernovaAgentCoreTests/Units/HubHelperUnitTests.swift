#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire
import Testing

extension CoreUnits {
    @Suite("PowerRouting: candidates and routing")
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
            actions: [PowerAction] = [.shutdown, .restart], ignoringApps: [PowerAction] = []
        ) -> RoutingPeer {
            RoutingPeer(
                handle: PeerHandle(rawValue: handle), role: .systemPeer,
                state: PeerSessionState(console: console, consoleSessionID: consoleSessionID),
                connectedOrder: handle, powerUsable: usable, actions: actions, ignoringAppsActions: ignoringApps)
        }

        /// A macOS guest at its login window: background sessions' peers, and the system peer reporting the
        /// console off and offering only shutdown without waiting for apps.
        static let atLoginWindow = [
            Self.session(1, "a", console: .off), Self.session(2, "b", console: .off),
            Self.system(9, console: .off, actions: [], ignoringApps: [.shutdown]),
        ]

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

        // MARK: Routing

        @Test(
            "At the login window a graceful action asks no peer and ends .untaken; without waiting for apps it goes to the system peer",
            arguments: [PowerAction.shutdown, .restart])
        func atLoginWindow(action: PowerAction) {
            var routing = PowerRouting()
            routing.begin(action, peers: Self.atLoginWindow)
            #expect(Self.outputs(&routing) == [.untaken(action, refusals: [])])
            #expect(!routing.isRouting)

            routing.begin(.shutdown, ignoringApps: true, peers: Self.atLoginWindow)
            #expect(Self.outputs(&routing) == [.ask(PeerHandle(rawValue: 9), .shutdown, ignoringApps: true)])
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
    }

    @Suite("ConsoleAuthority: the session peers on the console")
    struct ConsoleAuthorityUnitTests {
        @Test("A system peer's report names the console's owner: a session only with its id")
        func consoleOwner() {
            #expect(PeerSessionState(console: .on, consoleSessionID: "c1").consoleOwner == .session("c1"))
            #expect(PeerSessionState(console: .on).consoleOwner == .unnamed)
            #expect(PeerSessionState(console: .unknown, consoleSessionID: "c1").consoleOwner == .unnamed)
            #expect(PeerSessionState(console: .off, consoleSessionID: "c1").consoleOwner == .noUserSession)
        }
    }

    @Suite("PeerConflict")
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

        @Test(
            "Session peers of different rank → the lower closes DUPLICATE_PEER, retry 60 s",
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
    }

    @Suite("FeatureStatus.merge: one status per feature across a VM's peers")
    struct FeatureStatusMergeUnitTests {
        static func table(_ rows: [(FeatureID, Availability<Data>)]) -> FeatureStatusTable {
            FeatureStatusTable(rows.map { (feature: $0.0, status: $0.1) })
        }

        @Test("No peer at all → every feature absent NO_AGENT")
        func noPeers() {
            let merged = FeatureStatus.merge([])
            #expect(merged.entries.map(\.feature) == [.power, .update, .logs, .clipboard, .drop, .drag, .itemTransfer])
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
    }
}
