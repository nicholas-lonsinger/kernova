#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaPortableTestSupport
import KernovaWire
import SwiftProtobuf
import Testing

/// `kernova_v2.proto`'s messages as its text declares them: each one's FROZEN mark, field numbers, and the fields
/// whose type is another message of the file.
private struct ProtoMessages {
    struct Message {
        var frozen: Bool
        var fields: [(number: Int, type: String)] = []
    }

    private(set) var messages: [String: Message] = [:]

    init(parsing text: String) {
        var comment: [Substring] = []
        var current: String?
        var depth = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.drop(while: \.isWhitespace)
            if line.hasPrefix("//") {
                comment.append(line)
                continue
            }
            defer { comment = [] }
            let code = line.firstRange(of: "//").map { line[..<$0.lowerBound] } ?? line
            let tokens = code.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).map(String.init)
            if depth == 0, tokens.count == 3, tokens[0] == "message", tokens[2] == "{" {
                current = tokens[1]
                messages[tokens[1]] = Message(frozen: comment.first?.hasPrefix("// FROZEN") == true)
            } else if depth > 0, let current, let field = Self.field(tokens) {
                messages[current]?.fields.append(field)
            }
            depth += code.count(where: { $0 == "{" }) - code.count(where: { $0 == "}" })
            if depth == 0 { current = nil }
        }
    }

    /// The number and type of the field `tokens` declare (`[repeated|optional] type name = number`), or nil for any
    /// other line: an enum value, a `reserved` range, a `oneof`.
    private static func field(_ tokens: [String]) -> (number: Int, type: String)? {
        let typeIndex = ["repeated", "optional"].contains(tokens.first) ? 1 : 0
        guard tokens.count == typeIndex + 4, tokens[typeIndex + 2] == "=", tokens[0] != "reserved",
            let number = Int(tokens[typeIndex + 3])
        else { return nil }
        return (number, tokens[typeIndex])
    }

    /// The fields of `name` whose type is a message of the file.
    func messageFields(of name: String) -> [(number: Int, type: String)] {
        messages[name]?.fields.filter { messages[$0.type] != nil } ?? []
    }
}

/// Each path of message-typed fields from a message: the field numbers to follow, and the message types they reach.
private func paths(from root: String, in proto: ProtoMessages) -> [[(number: Int, type: String)]] {
    var found: [[(number: Int, type: String)]] = [[]]
    func walk(_ path: [(number: Int, type: String)], at name: String) {
        for field in proto.messageFields(of: name) {
            guard field.type != root, !path.contains(where: { $0.type == field.type }) else { continue }
            let next = path + [field]
            found.append(next)
            walk(next, at: field.type)
        }
    }
    walk([], at: root)
    return found
}

private func varint(_ value: UInt64) -> Data {
    var value = value
    var bytes = Data()
    while value >= 0x80 {
        bytes.append(UInt8(value & 0x7F) | 0x80)
        value >>= 7
    }
    bytes.append(UInt8(value))
    return bytes
}

/// `innermost` as the body of the message `path` reaches, nested in each length-delimited field the path follows.
private func nested(_ innermost: Data, along path: [(number: Int, type: String)]) -> Data {
    path.reversed().reduce(innermost) { inner, field in
        varint(UInt64(field.number) << 3 | 2) + varint(UInt64(inner.count)) + inner
    }
}

private enum Outcome: Equatable {
    case decoded
    case refused(WireDecodingError)
    /// The type is neither a `FrozenWireMessage` nor a `CurrentOnlyWireMessage`.
    case unclassified
}

private func decodeFrozen<M: FrozenWireMessage>(_: M.Type, _ bytes: Data) throws(WireDecodingError) {
    _ = try M(wire: bytes)
}

private func decodeCurrentOnly<M: CurrentOnlyWireMessage>(_: M.Type, _ bytes: Data) throws(WireDecodingError) {
    _ = try M(wire: bytes)
}

/// `bytes` decoded by `init(wire:)` as `type`, in the mode its conformance picks.
private func outcome(_ type: any SwiftProtobuf.Message.Type, _ bytes: Data) -> Outcome {
    do {
        if let frozen = type as? any FrozenWireMessage.Type {
            try decodeFrozen(frozen, bytes)
        } else if let currentOnly = type as? any CurrentOnlyWireMessage.Type {
            try decodeCurrentOnly(currentOnly, bytes)
        } else {
            return .unclassified
        }
        return .decoded
    } catch {
        return .refused(error)
    }
}

@Suite("Wire message decoding")
struct WireMessageTests {
    /// Every message the generated code declares.
    static let types: [any SwiftProtobuf.Message.Type] = [
        Kernova_V2_Open.self, Kernova_V2_Error.self, Kernova_V2_ItemFailure.self, Kernova_V2_SessionMessage.self,
        Kernova_V2_Hello.self, Kernova_V2_PeerIdentity.self, Kernova_V2_PeerState.self, Kernova_V2_FeatureAdvert.self,
        Kernova_V2_Absence.self, Kernova_V2_CapabilityUpdate.self, Kernova_V2_PolicyUpdate.self,
        Kernova_V2_FeaturePolicy.self, Kernova_V2_SessionExtension.self, Kernova_V2_PowerCapability.self,
        Kernova_V2_PowerRequest.self, Kernova_V2_PowerProgress.self, Kernova_V2_PowerOutcome.self,
        Kernova_V2_BlockingApp.self, Kernova_V2_UpdateCapability.self, Kernova_V2_UpdateManifest.self,
        Kernova_V2_UpdateAvailable.self, Kernova_V2_UpdatePull.self, Kernova_V2_UpdateResult.self,
        Kernova_V2_LogCapability.self, Kernova_V2_LogPolicy.self, Kernova_V2_LogOpen.self, Kernova_V2_LogSegment.self,
        Kernova_V2_LogRecord.self, Kernova_V2_LogBatch.self, Kernova_V2_ItemTransferCapability.self,
        Kernova_V2_TypeDescriptor.self, Kernova_V2_Representation.self, Kernova_V2_Item.self,
        Kernova_V2_ItemSetHeader.self, Kernova_V2_PullRequest.self, Kernova_V2_PullOutcome.self,
        Kernova_V2_Timespec.self, Kernova_V2_Xattr.self, Kernova_V2_PlainStorage.self, Kernova_V2_Lz4Storage.self,
        Kernova_V2_DecmpfsStorage.self, Kernova_V2_EntryHeader.self, Kernova_V2_EndRecord.self,
        Kernova_V2_ClipboardCapability.self, Kernova_V2_ClipboardPolicy.self, Kernova_V2_DropCapability.self,
        Kernova_V2_DropPolicy.self, Kernova_V2_DropLanded.self, Kernova_V2_DragCapability.self,
        Kernova_V2_DragPolicy.self, Kernova_V2_DragTake.self, Kernova_V2_DragTakeControl.self,
        Kernova_V2_DragCatcher.self, Kernova_V2_DragDeliver.self, Kernova_V2_DragTakeReport.self,
        Kernova_V2_DragTakeOutcome.self,
    ]

    /// A field no message defines, number 2047, as a varint of 1.
    static let unknownField = Data([0xF8, 0x7F, 0x01])

    @Test("A field this build does not define is refused wherever a current-only message holds it, and only there")
    func unknownFieldAtEveryNesting() throws {
        let text = try String(
            decoding: Data(contentsOf: SourceTree.url("KernovaKit/Sources/KernovaWire/Proto/kernova_v2.proto")),
            as: UTF8.self)
        let proto = ProtoMessages(parsing: text)
        let byName = Dictionary(
            uniqueKeysWithValues: Self.types.map { (String($0.protoMessageName.dropFirst("kernova.v2.".count)), $0) })
        #expect(Set(byName.keys) == Set(proto.messages.keys))
        #expect(proto.messages.values.allSatisfy { !$0.fields.contains { $0.number == 2047 } })

        for (name, message) in proto.messages.sorted(by: { $0.key < $1.key }) {
            for field in proto.messageFields(of: name) where message.frozen {
                #expect(proto.messages[field.type]?.frozen == true, "FROZEN \(name) holds current-only \(field.type)")
            }
            guard let type = byName[name] else { continue }
            for path in paths(from: name, in: proto) {
                let place = ([name] + path.map { "\($0.number):\($0.type)" }).joined(separator: " > ")
                let refused = !message.frozen && path.allSatisfy { proto.messages[$0.type]?.frozen == false }
                #expect(outcome(type, nested(Data(), along: path)) == .decoded, "\(place) without the field")
                #expect(
                    outcome(type, nested(Self.unknownField, along: path))
                        == (refused ? .refused(.unknownField) : .decoded),
                    "\(place)")
            }
        }
    }
}
