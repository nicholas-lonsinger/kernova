#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf
import Testing

@Suite("Item transfer schema")
struct ItemTransferSchemaTests {
    @Test("The features, kinds and error codes carry the proto's numbers")
    func numbers() {
        #expect(FeatureID.itemTransfer.rawValue == 13)
        #expect(StreamKind.itemPullByHost.rawValue == 1001)
        #expect(StreamKind.itemPullByPeer.rawValue == 1002)
        #expect(StreamKind.testBulkByPeer.rawValue == 9000)
        #expect(StreamKind.testBulkByHost.rawValue == 9001)
        #expect(FeatureID.clipboard.rawValue == 10)
        #expect(FeatureID.drop.rawValue == 11)
        #expect(FeatureID.drag.rawValue == 12)
        #expect(StreamKind.clipboardOfferByHost.rawValue == 1000)
        #expect(StreamKind.dropOffer.rawValue == 1003)
        #expect(StreamKind.dragOffer.rawValue == 1004)
        #expect(StreamKind.dragTake.rawValue == 1005)
        #expect(StreamKind.clipboardOfferByPeer.rawValue == 1006)
        #expect(ErrorCode.dragNotCurrent.rawValue == 1005)
        #expect(ErrorCode.dragPressOver.rawValue == 1006)
        #expect(Kernova_V2_DragTakeOutcome.Kind.taken.rawValue == 1)
        #expect(Kernova_V2_DragTakeOutcome.Kind.refused.rawValue == 2)
        #expect(ErrorCode.itemOfferStale.rawValue == 1000)
        #expect(ErrorCode.itemRepresentationUnavailable.rawValue == 1001)
        #expect(ErrorCode.itemContainerMalformed.rawValue == 1002)
        #expect(ErrorCode.itemUnpackRefused.rawValue == 1003)
        #expect(ErrorCode.itemDecmpfsRefused.rawValue == 1004)
        #expect(Codec.lz4.rawValue == 1)
        #expect(Kernova_V2_Representation.Storage.inline.rawValue == 1)
        #expect(Kernova_V2_Representation.Storage.file.rawValue == 2)
        #expect(Kernova_V2_Representation.Storage.folder.rawValue == 3)
        #expect(Kernova_V2_PullOutcome.Kind.landed.rawValue == 1)
        #expect(Kernova_V2_PullOutcome.Kind.failed.rawValue == 2)
        #expect(Kernova_V2_EntryHeader.TypeEnum.data.rawValue == 1)
        #expect(Kernova_V2_EntryHeader.TypeEnum.file.rawValue == 2)
        #expect(Kernova_V2_EntryHeader.TypeEnum.directory.rawValue == 3)
        #expect(Kernova_V2_EntryHeader.TypeEnum.symlink.rawValue == 4)
    }

    /// Each field set to a value whose encoding is one byte past the tag, so
    /// the encoded tags read off the bytes in field order.
    @Test("PullRequest's fields carry the proto's numbers")
    func pullRequestFields() throws {
        var request = Kernova_V2_PullRequest()
        request.token = Data([0xAA])
        request.item = 1
        request.representation = 1
        request.byteCeiling = 1
        request.decmpfsTypes = [8]
        request.codecs = [.lz4]
        let bytes: [UInt8] = try request.serializedBytes()
        // 5 and 6 are packed: tag, length 1, the value.
        #expect(bytes == [0x0A, 1, 0xAA, 0x10, 1, 0x18, 1, 0x20, 1, 0x2A, 1, 8, 0x32, 1, 1])
    }

    @Test("EntryHeader's fields carry the proto's numbers")
    func entryHeaderFields() throws {
        var header = Kernova_V2_EntryHeader()
        header.depth = 1
        header.name = Data([0x61])
        header.type = .file
        header.mode = 1
        header.darwinFlags = 1
        header.modificationTime = Kernova_V2_Timespec()
        header.birthTime = Kernova_V2_Timespec()
        header.xattrs = [Kernova_V2_Xattr()]
        header.symlinkTarget = Data([0x62])
        #expect(
            try header.serializedBytes() == [
                0x08, 1, 0x12, 1, 0x61, 0x18, 2, 0x20, 1, 0x28, 1, 0x32, 0, 0x3A, 0, 0x42, 0, 0x4A, 1, 0x62,
            ])

        header = Kernova_V2_EntryHeader()
        header.plain = Kernova_V2_PlainStorage()
        #expect(try header.serializedBytes() == [0x52, 0])
        header.lz4 = Kernova_V2_Lz4Storage()
        #expect(try header.serializedBytes() == [0x5A, 0])
        var decmpfs = Kernova_V2_DecmpfsStorage()
        decmpfs.attribute = Data([0x63])
        header.decmpfs = decmpfs
        header.resourceForkSize = 1
        #expect(try header.serializedBytes() == [0x62, 3, 0x0A, 1, 0x63, 0x68, 1])
    }

    @Test("The item-set, outcome and record messages carry the proto's numbers")
    func itemSetAndRecordFields() throws {
        var setHeader = Kernova_V2_ItemSetHeader()
        setHeader.concealed = true
        setHeader.count = 1
        setHeader.token = Data([0xAA])
        #expect(try setHeader.serializedBytes() == [0x08, 1, 0x18, 1, 0x22, 1, 0xAA])

        var type = TypeDescriptor()
        type.mime = "a"
        type.native = ["b"]
        #expect(try type.serializedBytes() == [0x0A, 1, 0x61, 0x12, 1, 0x62])

        var representation = Kernova_V2_Representation()
        representation.type = TypeDescriptor()
        representation.storage = .file
        representation.promised = true
        representation.sizeEstimate = 1
        representation.name = Data([0x61])
        #expect(try representation.serializedBytes() == [0x0A, 0, 0x10, 2, 0x18, 1, 0x20, 1, 0x2A, 1, 0x61])

        var item = Kernova_V2_Item()
        item.representations = [Kernova_V2_Representation()]
        #expect(try item.serializedBytes() == [0x0A, 0])

        var outcome = Kernova_V2_PullOutcome()
        outcome.kind = .failed
        outcome.error = Kernova_V2_Error()
        #expect(try outcome.serializedBytes() == [0x08, 2, 0x12, 0])

        var time = Kernova_V2_Timespec()
        time.seconds = 1
        time.nanoseconds = 1
        #expect(try time.serializedBytes() == [0x08, 1, 0x10, 1])

        var xattr = Kernova_V2_Xattr()
        xattr.name = Data([0x61])
        xattr.value = Data([0x62])
        #expect(try xattr.serializedBytes() == [0x0A, 1, 0x61, 0x12, 1, 0x62])

        var plain = Kernova_V2_PlainStorage()
        plain.size = 1
        #expect(try plain.serializedBytes() == [0x08, 1])
        var lz4 = Kernova_V2_Lz4Storage()
        lz4.size = 1
        #expect(try lz4.serializedBytes() == [0x08, 1])

        var end = Kernova_V2_EndRecord()
        end.entries = 1
        end.bytes = 1
        #expect(try end.serializedBytes() == [0x08, 1, 0x10, 1])
    }

    @Test("The drag take's messages carry the proto's numbers")
    func dragTakeFields() throws {
        var take = Kernova_V2_DragTake()
        take.token = Data([0xAA])
        #expect(try take.serializedBytes() == [0x0A, 1, 0xAA])

        var outcome = Kernova_V2_DragTakeOutcome()
        outcome.kind = .refused
        outcome.error = Kernova_V2_Error()
        #expect(try outcome.serializedBytes() == [0x08, 2, 0x12, 0])
    }
}

@Suite("Choosing a representation for a destination")
struct RepresentationChoiceTests {
    private static func descriptor(_ mime: String, _ native: String...) -> TypeDescriptor {
        var type = TypeDescriptor()
        type.mime = mime
        type.native = native
        return type
    }

    private static func item(_ types: (TypeDescriptor, Kernova_V2_Representation.Storage)...) -> Kernova_V2_Item {
        var item = Kernova_V2_Item()
        item.representations = types.map { type, storage in
            var representation = Kernova_V2_Representation()
            representation.type = type
            representation.storage = storage
            return representation
        }
        return item
    }

    private static let uti = NativeTypeNamespace.appleUTI
    private static let cf = NativeTypeNamespace.windowsClipboardFormat

    @Test("A namespace prefixes its names")
    func qualifiedNames() {
        #expect(Self.uti.qualified("public.png") == "apple-uti/public.png")
        #expect(Self.cf.qualified("PNG") == "win-cf/PNG")
    }

    @Test("A shared native name beats an earlier MIME match")
    func nativeBeforeMIME() {
        let item = Self.item(
            (Self.descriptor("image/png"), .inline),
            (Self.descriptor("image/tiff", Self.uti.qualified("public.tiff")), .inline))
        let accepted = [
            Self.descriptor("image/png"),
            Self.descriptor("image/x-other", Self.uti.qualified("public.tiff")),
        ]
        #expect(item.representationIndex(accepting: accepted) == 1)
    }

    @Test("Without a shared native name, MIME decides in the destination's order")
    func mimeInDestinationOrder() {
        let item = Self.item(
            (Self.descriptor("text/plain", Self.cf.qualified("CF_UNICODETEXT")), .inline),
            (Self.descriptor("text/html", Self.cf.qualified("HTML Format")), .inline))
        let accepted = [
            Self.descriptor("text/html", Self.uti.qualified("public.html")),
            Self.descriptor("text/plain", Self.uti.qualified("public.utf8-plain-text")),
        ]
        #expect(item.representationIndex(accepting: accepted) == 1)
    }

    @Test("The destination's earliest accepted type wins, then the sender's earliest representation")
    func destinationOrderThenSenderOrder() {
        let png = Self.uti.qualified("public.png")
        let tiff = Self.uti.qualified("public.tiff")
        let item = Self.item(
            (Self.descriptor("", tiff), .inline),
            (Self.descriptor("", png), .inline),
            (Self.descriptor("", png, tiff), .file))
        #expect(item.representationIndex(accepting: [Self.descriptor("", png), Self.descriptor("", tiff)]) == 1)
        #expect(item.representationIndex(accepting: [Self.descriptor("", tiff), Self.descriptor("", png)]) == 0)
    }

    @Test("An empty MIME type matches nothing")
    func emptyMIMEMatchesNothing() {
        let item = Self.item((Self.descriptor("", Self.cf.qualified("PNG")), .inline))
        #expect(item.representationIndex(accepting: [Self.descriptor("", Self.uti.qualified("public.png"))]) == nil)
    }

    @Test("A representation of unrecognized storage is never chosen")
    func unrecognizedStorageSkipped() {
        let item = Self.item(
            (Self.descriptor("image/png"), .unspecified),
            (Self.descriptor("image/png"), .UNRECOGNIZED(9)),
            (Self.descriptor("image/png"), .folder))
        #expect(item.representationIndex(accepting: [Self.descriptor("image/png")]) == 2)
        let unoffered = Self.item((Self.descriptor("image/png"), .unspecified))
        #expect(unoffered.representationIndex(accepting: [Self.descriptor("image/png")]) == nil)
    }

    @Test("Nothing accepted chooses nothing")
    func nothingAccepted() {
        #expect(Self.item((Self.descriptor("image/png"), .inline)).representationIndex(accepting: []) == nil)
    }
}
