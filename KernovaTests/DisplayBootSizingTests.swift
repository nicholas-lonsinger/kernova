import CoreGraphics
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("DisplayBootSizing Tests", .caseScoped)
struct DisplayBootSizingTests {
    // MARK: - Fitting a surface

    @Test("A 1× surface maps points to pixels 1:1 at standard density")
    func fitsOneToOneAtStandardScale() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 1440, height: 900), backingScaleFactor: 1)

        #expect(resolution.width == 1440)
        #expect(resolution.height == 900)
        #expect(resolution.ppi == DisplayBootSizing.standardPixelsPerInch)
    }

    @Test("A 2× surface doubles the pixel count and reports HiDPI density")
    func fitsRetinaAtDoubleScale() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 1440, height: 900), backingScaleFactor: 2)

        #expect(resolution.width == 2880)
        #expect(resolution.height == 1800)
        #expect(resolution.ppi == DisplayBootSizing.hiDPIPixelsPerInch)
    }

    @Test("Fractional pixel counts round down; a 1× surface keeps an odd count")
    func roundsDownToWholePixels() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 1401.7, height: 903.2), backingScaleFactor: 1)

        #expect(resolution.width == 1401)
        #expect(resolution.height == 903)
    }

    @Test("A 2× surface stores an even pixel count, so its base halves exactly")
    func retinaFitRoundsToEven() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 700.7, height: 450.2), backingScaleFactor: 2)

        #expect(resolution.width == 1400)
        #expect(resolution.height == 900)
    }

    @Test("A small surface is taken as it is, down to 1 pixel")
    func smallSurfaceIsTaken() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 640, height: 400), backingScaleFactor: 1)

        #expect(resolution.width == 640)
        #expect(resolution.height == 400)
    }

    @Test("A large surface is taken whole: Kernova sets no maximum")
    func largeSurfaceIsTaken() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 6000, height: 5000), backingScaleFactor: 2)

        #expect(resolution.width == 12000)
        #expect(resolution.height == 10000)
    }

    @Test("A degenerate surface clamps to 1 × 1 rather than trapping", arguments: [1.0, 2.0])
    func degenerateSurfaceClampsToFloor(scale: CGFloat) {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 0, height: -10), backingScaleFactor: scale)
        let factor = scale >= 2 ? 2 : 1

        #expect(resolution.width == DisplayBootSizing.minimumDimension * factor)
        #expect(resolution.height == DisplayBootSizing.minimumDimension * factor)
    }

    // MARK: - HiDPI rewrite

    @Test("doubled and halved round-trip a mid-range resolution")
    func doubledHalvedRoundTrip() {
        let base = DisplayBootSizing.Resolution(
            width: 1280, height: 800, ppi: DisplayBootSizing.standardPixelsPerInch)

        let retina = DisplayBootSizing.doubled(base)
        #expect(retina == DisplayBootSizing.Resolution(width: 2560, height: 1600, ppi: 220))

        #expect(DisplayBootSizing.halved(retina) == base)
    }

    @Test("Doubling the largest base an Int holds does not overflow")
    func doubledNeverOverflows() {
        let huge = DisplayBootSizing.Resolution(
            width: .max, height: .max, ppi: DisplayBootSizing.standardPixelsPerInch)

        let retina = DisplayBootSizing.doubled(huge)

        #expect(retina.width == (Int.max / 2) * 2)
        #expect(DisplayBootSizing.halved(retina).width == Int.max / 2)
    }

    @Test("halved clamps at 1")
    func halvedClampsAtFloor() {
        let small = DisplayBootSizing.Resolution(
            width: 1, height: 3, ppi: DisplayBootSizing.hiDPIPixelsPerInch)

        let halved = DisplayBootSizing.halved(small)

        #expect(halved == DisplayBootSizing.Resolution(width: 1, height: 1, ppi: 144))
    }

    @Test("rescaled picks the direction from the flag")
    func rescaledFollowsTheFlag() {
        let base = DisplayBootSizing.Resolution(
            width: 1280, height: 800, ppi: DisplayBootSizing.standardPixelsPerInch)
        let retina = DisplayBootSizing.doubled(base)

        #expect(DisplayBootSizing.rescaled(base, toHiDPI: true) == retina)
        #expect(DisplayBootSizing.rescaled(retina, toHiDPI: false) == base)
    }

    @Test("isHiDPI switches at 200 ppi")
    func isHiDPIBoundary() {
        #expect(!DisplayBootSizing.isHiDPI(ppi: 199))
        #expect(DisplayBootSizing.isHiDPI(ppi: 200))
        #expect(!DisplayBootSizing.isHiDPI(ppi: DisplayBootSizing.standardPixelsPerInch))
        #expect(DisplayBootSizing.isHiDPI(ppi: DisplayBootSizing.hiDPIPixelsPerInch))
    }

    // MARK: - A chosen base size

    @Test("A base size's bounds are 1 up to what an Int's pixel count holds", arguments: [false, true])
    func baseBounds(hiDPI: Bool) {
        let bounds = DisplayBootSizing.baseBounds(hiDPI: hiDPI)

        #expect(bounds.lower == 1)
        #expect(bounds.upper == Int.max / (hiDPI ? 2 : 1))
    }

    @Test("An odd HiDPI base keeps its parity, so halving the stored pixels gives it back")
    func hiDPIBaseKeepsAnOddSize() {
        let retina = DisplayBootSizing.resolution(base: 801, height: 901, hiDPI: true)

        #expect(retina == DisplayBootSizing.Resolution(width: 1602, height: 1802, ppi: 220))
    }

    @Test("A standard base keeps an odd size")
    func standardBaseKeepsAnOddSize() {
        let standard = DisplayBootSizing.resolution(base: 1281, height: 801, hiDPI: false)

        #expect(
            standard
                == DisplayBootSizing.Resolution(
                    width: 1281, height: 801, ppi: DisplayBootSizing.standardPixelsPerInch))
    }
}
