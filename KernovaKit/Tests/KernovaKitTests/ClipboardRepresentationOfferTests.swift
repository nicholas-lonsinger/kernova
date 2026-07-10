import Foundation
import Testing

@testable import KernovaKit

/// Exercises the shared `offerRepresentationInfo` projection that both the host
/// "Copy to Mac" offer path and the guest inbound-offer path use to populate
/// `ClipboardOffer.repInfo` from a representation.
@Suite("ClipboardContent.Representation.offerRepresentationInfo")
struct ClipboardRepresentationOfferTests {
    private let dummyURL = URL(fileURLWithPath: "/tmp/kernova-clipboard-test")

    @Test("inline (filename-less) content offers isInline with no filename")
    func filenamelessContentOffersInline() {
        let rep = ClipboardContent.Representation(
            uti: ClipboardContent.utf8TextUTI, data: Data("hi".utf8))
        let info = rep.offerRepresentationInfo
        #expect(info.uti == ClipboardContent.utf8TextUTI)
        #expect(info.byteCount == UInt64(rep.byteCount))
        #expect(info.filename.isEmpty)
        #expect(info.isInline)
        #expect(!info.isDirectory)
    }

    @Test("an image file payload offers isInline with its filename")
    func imageFileOffersInline() {
        let rep = ClipboardContent.Representation(
            uti: "public.png", fileURL: dummyURL, byteCount: 10, filename: "photo.png")
        let info = rep.offerRepresentationInfo
        #expect(info.uti == "public.png")
        #expect(info.byteCount == 10)
        #expect(info.filename == "photo.png")
        #expect(info.isInline)
        #expect(!info.isDirectory)
    }

    @Test("a non-image file payload offers file-only")
    func nonImageFileOffersFileOnly() {
        let rep = ClipboardContent.Representation(
            uti: "public.plain-text", fileURL: dummyURL, byteCount: 10, filename: "notes.txt")
        let info = rep.offerRepresentationInfo
        #expect(info.uti == "public.plain-text")
        #expect(info.byteCount == 10)
        #expect(info.filename == "notes.txt")
        #expect(!info.isInline)
        #expect(!info.isDirectory)
    }

    @Test("a directory payload offers file-only and isDirectory")
    func directoryOffersFileOnlyAndDirectory() {
        let rep = ClipboardContent.Representation(
            uti: "public.folder", fileURL: dummyURL, byteCount: 10, filename: "Pictures",
            isDirectory: true)
        let info = rep.offerRepresentationInfo
        #expect(info.uti == "public.folder")
        #expect(info.byteCount == 10)
        #expect(info.filename == "Pictures")
        #expect(!info.isInline)
        #expect(info.isDirectory)
    }
}
