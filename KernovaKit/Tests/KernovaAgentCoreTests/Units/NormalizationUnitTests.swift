#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import SwiftProtobuf
import Testing

extension CoreUnits {
    @Suite("Normalization of received identity and state strings")
    struct NormalizationUnitTests {
        /// `WireFrames.hello(role:)` with `edit` applied to its Hello.
        static func hello(_ role: Kernova_V2_PeerIdentity.Role, _ edit: (inout Kernova_V2_Hello) -> Void) -> Frame {
            let base = WireFrames.hello(role: role, scope: role == .systemPeer ? .system : .user)
            var message = (try? Kernova_V2_SessionMessage(serializedBytes: base.payload)) ?? Kernova_V2_SessionMessage()
            var hello = message.hello
            edit(&hello)
            message.hello = hello
            return WireFrames.message(0, message)
        }

        /// What a host (or, for a host's Hello, a session peer) reads from `frame`.
        static func received(_ frame: Frame, byPeer: Bool = false) -> (RemoteHello?, [ConnectionEvent]) {
            var wire = byPeer ? Wire.peer() : Wire.host()
            wire.feed([frame], preamble: true)
            let events = wire.takeEvents()
            for event in events {
                if case .helloReceived(let hello) = event { return (hello, events) }
            }
            return (nil, events)
        }

        static func advert(_ feature: FeatureID, params: Data? = nil, absent: AbsenceReason? = nil, detail: String = "")
            -> Kernova_V2_FeatureAdvert
        {
            var advert = Kernova_V2_FeatureAdvert()
            advert.feature = feature
            advert.version = 1
            if let params { advert.params = params }
            if let absent {
                advert.absent.reason = absent
                advert.absent.debugDetail = detail
            }
            return advert
        }

        // MARK: Strings

        @Test("Cc and Cf scalars are stripped; every other category is kept")
        func stripsControlAndFormat() {
            let text = "a\u{0}b\u{7}c\n\td\u{7F}e\u{200B}f\u{202E}g\u{FEFF}h\u{AD}i é😀 e\u{301}"
            #expect(Normalize.display(text, maxBytes: 64) == "abcdefghi é😀 e\u{301}")
        }

        @Test(
            "Strings are clipped to 64 UTF-8 bytes on a scalar boundary",
            arguments: [
                (String(repeating: "x", count: 64), 64), (String(repeating: "x", count: 65), 64),
                ("a" + String(repeating: "é", count: 40), 63), (String(repeating: "😀", count: 17), 64),
                (String(repeating: "€", count: 30), 63),
            ])
        func clipsOnScalarBoundary(_ text: String, _ bytes: Int) {
            let clipped = Normalize.display(text, maxBytes: 64)
            #expect(clipped.utf8.count == bytes)
            #expect(text.hasPrefix(clipped))
        }

        @Test("Stripping comes before clipping, so stripped scalars cost no bytes")
        func stripsBeforeClipping() {
            let text = String(repeating: "\u{200B}", count: 10) + String(repeating: "x", count: 64)
            #expect(Normalize.display(text, maxBytes: 64) == String(repeating: "x", count: 64))
        }

        @Test("Every string in a received PeerIdentity and PeerState is normalized")
        func identityAndStateStrings() {
            let long = "\u{202E}" + String(repeating: "é", count: 40)
            let frame = Self.hello(.sessionPeer) { hello in
                hello.identity.osVersion = long
                hello.identity.osBuild = "b\u{0}uild"
                hello.identity.osDistribution = long
                hello.identity.versionLabel = "v\u{200B}1"
                hello.state.sessionID = "s\u{7}1"
                hello.state.userName = long
            }
            let (hello, _) = Self.received(frame)
            let clipped = String(repeating: "é", count: 32)
            #expect(hello?.claim.osVersion == clipped)
            #expect(hello?.claim.osBuild == "build")
            #expect(hello?.claim.osDistribution == clipped)
            #expect(hello?.claim.versionLabel == "v1")
            #expect(hello?.state?.sessionID == "s1")
            #expect(hello?.state?.userName == clipped)
        }

        @Test("A system peer's console_session_id is normalized")
        func consoleSessionID() {
            let frame = Self.hello(.systemPeer) {
                $0.state.consoleSessionID = "\u{FEFF}c" + String(repeating: "1", count: 80)
            }
            let (hello, _) = Self.received(frame)
            #expect(hello?.state?.consoleSessionID == "c" + String(repeating: "1", count: 63))
        }

        @Test("A session peer whose session_id normalizes to empty is a PROTOCOL_ERROR")
        func emptyAfterNormalization() {
            let (hello, events) = Self.received(Self.hello(.sessionPeer) { $0.state.sessionID = "\u{7}\u{200B}" })
            #expect(hello == nil)
            #expect(
                events.contains { event in
                    if case .closed(.closedLocally(let error)) = event { return error.code == .protocolError }
                    return false
                })
        }

        // MARK: Bytes

        @Test("payload_hash past 32 bytes is clipped")
        func payloadHashClipped() {
            let hash = Data(0..<40)
            let (hello, _) = Self.received(Self.hello(.sessionPeer) { $0.identity.payloadHash = hash })
            #expect(hello?.claim.payloadHash == Data(0..<32))
        }

        @Test("session_token past 32 bytes is clipped")
        func sessionTokenClipped() {
            let (hello, _) = Self.received(Self.hello(.host) { $0.sessionToken = Data(0..<40) }, byPeer: true)
            #expect(hello?.sessionToken == Data(0..<32))
        }

        @Test("instance_id reads as empty unless exactly 16 bytes", arguments: [0, 15, 16, 17, 32])
        func instanceID(_ count: Int) {
            let id = Data(repeating: 0x5C, count: count)
            let (hello, _) = Self.received(Self.hello(.sessionPeer) { $0.identity.instanceID = id })
            #expect(hello?.claim.instanceID == (count == 16 ? id : Data()))
        }

        // MARK: Features

        @Test("Unknown features are ignored and a repeated feature keeps its first entry")
        func unknownAndRepeated() {
            let frame = Self.hello(.sessionPeer) { hello in
                hello.features = [
                    Self.advert(.UNRECOGNIZED(77), params: Data()), Self.advert(.logs, absent: .notPermitted),
                    Self.advert(.logs, params: Data()), Self.advert(.power, params: Data()),
                ]
            }
            let (hello, _) = Self.received(frame)
            #expect(hello?.adverts.map(\.feature) == [.power, .logs])
            #expect(hello?.adverts.last?.advert.availability == .absent(.notPermitted, debugDetail: ""))
        }

        @Test("An advert with neither params nor absent is absent UNSPECIFIED")
        func neither() {
            let (hello, _) = Self.received(Self.hello(.sessionPeer) { $0.features = [Self.advert(.logs)] })
            #expect(hello?.adverts.first?.advert.availability == .absent(.unspecified, debugDetail: ""))
        }

        @Test(
            "An Absence.reason outside 1–99 reads as UNSPECIFIED",
            arguments: [
                (AbsenceReason.notOnConsole, AbsenceReason.notOnConsole), (.turnedOffInGuest, .turnedOffInGuest),
                (.versionMismatch, .unspecified), (.noAgent, .unspecified), (.UNRECOGNIZED(500), .unspecified),
                (.UNRECOGNIZED(99), .UNRECOGNIZED(99)),
            ])
        func absenceReason(_ sent: AbsenceReason, _ read: AbsenceReason) {
            let (hello, _) = Self.received(
                Self.hello(.sessionPeer) { $0.features = [Self.advert(.logs, absent: sent)] })
            #expect(hello?.adverts.first?.advert.availability == .absent(read, debugDetail: ""))
        }

        @Test("debug_detail is clipped to 1 KiB")
        func debugDetail() {
            let detail = String(repeating: "d", count: 2_000)
            let frame = Self.hello(.sessionPeer) {
                $0.features = [Self.advert(.logs, absent: .notPermitted, detail: detail)]
            }
            let (hello, _) = Self.received(frame)
            #expect(
                hello?.adverts.first?.advert.availability
                    == .absent(.notPermitted, debugDetail: String(repeating: "d", count: 1_024)))
        }

        @Test("A received Error's debug_detail is clipped to 1 KiB")
        func errorDebugDetail() {
            var error = Kernova_V2_Error()
            error.code = .cancelled
            error.debugDetail = String(repeating: "e", count: 3_000)
            #expect(WireError(received: error).debugDetail.utf8.count == 1_024)
        }
    }
}
