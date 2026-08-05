import Foundation
import Testing

@testable import KernovaKit

@Suite("ClipboardConnectionTag")
struct ClipboardConnectionTagTests {
    @Test("successive tags are distinct and increase")
    func sequenceIncreases() {
        // The counter is process-wide, so only the ordering — never the absolute
        // values — is asserted; a parallel suite may mint between these.
        let first = ClipboardConnectionTag.nextHost()
        let second = ClipboardConnectionTag.nextGuest()
        let third = ClipboardConnectionTag.nextHost()
        #expect(first.sequence < second.sequence)
        #expect(second.sequence < third.sequence)
        #expect(first.description != third.description)
    }

    @Test("the host form renders the bare sequence")
    func hostForm() {
        let tag = ClipboardConnectionTag.nextHost()
        #expect(tag.processIdentifier == nil)
        #expect(tag.description == "\(tag.sequence)")
    }

    @Test("the guest form renders <pid>.<sequence>")
    func guestForm() {
        let tag = ClipboardConnectionTag.nextGuest()
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(tag.processIdentifier == pid)
        #expect(tag.description == "\(pid).\(tag.sequence)")
    }

    @Test("the pre-connection guest tag is sequence 0 and mints nothing")
    func guestUnconnected() {
        let tag = ClipboardConnectionTag.guestUnconnected
        #expect(tag.sequence == 0)
        #expect(tag.description == "\(ProcessInfo.processInfo.processIdentifier).0")
        #expect(ClipboardConnectionTag.nextGuest().sequence > 0)
    }
}
