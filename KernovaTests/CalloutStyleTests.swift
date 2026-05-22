import Testing
import AppKit
@testable import Kernova

@Suite("CalloutStyle Tests")
@MainActor
struct CalloutStyleTests {
    @Test("bodyWidth equals width minus 2× padding")
    func bodyWidthMath() {
        #expect(CalloutStyle.bodyWidth == CalloutStyle.width - CalloutStyle.padding * 2)
    }

    @Test("makeCalloutHeadline configures font and wrapping")
    func headlineFactory() {
        let label = makeCalloutHeadline("Hello")
        #expect(label.stringValue == "Hello")
        #expect(label.font == CalloutStyle.headlineFont)
        #expect(label.lineBreakMode == .byWordWrapping)
        #expect(label.maximumNumberOfLines == 0)
        #expect(label.preferredMaxLayoutWidth == CalloutStyle.bodyWidth)
    }

    @Test("makeCalloutBody uses default secondary color")
    func bodyFactoryDefaultColor() {
        let label = makeCalloutBody("Some text")
        #expect(label.stringValue == "Some text")
        #expect(label.font == CalloutStyle.bodyFont)
        #expect(label.textColor == CalloutStyle.bodyColor)
        #expect(label.preferredMaxLayoutWidth == CalloutStyle.bodyWidth)
    }

    @Test("makeCalloutBody honors custom color")
    func bodyFactoryCustomColor() {
        let label = makeCalloutBody("Lead", color: .labelColor)
        #expect(label.textColor == .labelColor)
    }
}
