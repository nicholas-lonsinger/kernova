import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaAppKitShared

@Suite("CalloutStyle Tests", .caseScoped)
@MainActor
struct CalloutStyleTests {
    @Test("makeCalloutBody is non-selectable")
    func bodyFactoryNonSelectable() {
        // `NSTextField(wrappingLabelWithString:)` defaults to selectable —
        // makeCalloutBody must explicitly override that.
        #expect(!makeCalloutBody("text").isSelectable)
    }

    @Test("makeCalloutHeadline is non-selectable")
    func headlineFactoryNonSelectable() {
        #expect(!makeCalloutHeadline("title").isSelectable)
    }

    @Test("makeCalloutCode is selectable and monospaced")
    func codeFactorySelectable() {
        let label = makeCalloutCode("mount -t virtiofs share0 /mnt/myshare")
        #expect(label.isSelectable)
        #expect(label.font?.isFixedPitch == true)
    }
}
