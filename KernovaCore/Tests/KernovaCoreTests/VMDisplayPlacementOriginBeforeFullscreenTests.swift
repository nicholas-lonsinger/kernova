import CoreGraphics
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("VMDisplayPlacement.originBeforeFullscreen", .caseScoped)
struct VMDisplayPlacementOriginBeforeFullscreenTests {
    private let window = CGRect(x: 40, y: 60, width: 1049, height: 700)

    @Test("A window already on the fullscreen screen keeps its windowed position")
    func onTargetStays() {
        let origin = VMDisplayPlacement.originBeforeFullscreen(
            windowFrame: window, isOnTarget: true, targetFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(origin == nil)
    }

    @Test("A window on another screen is centred on the fullscreen screen")
    func elsewhereCentres() {
        let origin = VMDisplayPlacement.originBeforeFullscreen(
            windowFrame: window, isOnTarget: false, targetFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1440))
        // (2560 − 1049) / 2 = 755.5 past x 1512; (1440 − 700) / 2 = 370 past y −200.
        #expect(origin == CGPoint(x: 2267.5, y: 170))
    }
}
