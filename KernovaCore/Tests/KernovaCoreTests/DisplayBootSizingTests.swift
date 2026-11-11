import CoreGraphics
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("DisplayBootSizing Tests", .caseScoped)
struct DisplayBootSizingTests {
    // MARK: - Fitting a surface

    @Test("A 2× surface stores an even pixel count, so its base halves exactly")
    func retinaFitRoundsToEven() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 700.7, height: 450.2), backingScaleFactor: 2)

        #expect(resolution.width == 1400)
        #expect(resolution.height == 900)
    }

    // MARK: - HiDPI rewrite

    @Test("halved clamps at 1")
    func halvedClampsAtFloor() {
        let small = DisplayBootSizing.Resolution(
            width: 1, height: 3, ppi: DisplayBootSizing.hiDPIPixelsPerInch)

        let halved = DisplayBootSizing.halved(small)

        #expect(halved == DisplayBootSizing.Resolution(width: 1, height: 1, ppi: 144))
    }

    @Test("isHiDPI switches at 200 ppi")
    func isHiDPIBoundary() {
        #expect(!DisplayBootSizing.isHiDPI(ppi: 199))
        #expect(DisplayBootSizing.isHiDPI(ppi: 200))
        #expect(!DisplayBootSizing.isHiDPI(ppi: DisplayBootSizing.standardPixelsPerInch))
        #expect(DisplayBootSizing.isHiDPI(ppi: DisplayBootSizing.hiDPIPixelsPerInch))
    }
}
