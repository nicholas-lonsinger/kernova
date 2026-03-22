import Testing
import Cocoa
@testable import Kernova

@Suite("NSImage.systemSymbol Tests")
struct NSImageExtensionsTests {

    @Test("Returns a valid image for a known system symbol")
    func knownSymbol() {
        let image = NSImage.systemSymbol("play.fill", accessibilityDescription: "Play")
        #expect(image.size != .zero)
    }

    // The failure path (unknown symbol) is not tested here because
    // systemSymbol triggers assertionFailure in debug builds by design.
}
