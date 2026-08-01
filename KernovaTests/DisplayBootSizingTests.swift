import CoreGraphics
import Testing

@testable import Kernova

@Suite("DisplayBootSizing Tests")
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

    @Test("Fractional and odd pixel counts round down to even")
    func roundsDownToEvenPixels() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 1401.7, height: 903.2), backingScaleFactor: 1)

        #expect(resolution.width == 1400)
        #expect(resolution.height == 902)
    }

    @Test("A surface below the floor clamps up to 800 × 600")
    func clampsUpToFloor() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 640, height: 400), backingScaleFactor: 1)

        #expect(resolution.width == DisplayBootSizing.minimumWidth)
        #expect(resolution.height == DisplayBootSizing.minimumHeight)
    }

    @Test("A surface above the ceiling clamps down to 8192")
    func clampsDownToCeiling() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 6000, height: 5000), backingScaleFactor: 2)

        #expect(resolution.width == DisplayBootSizing.maximumDimension)
        #expect(resolution.height == DisplayBootSizing.maximumDimension)
    }

    @Test("A degenerate surface clamps to the floor rather than trapping")
    func degenerateSurfaceClampsToFloor() {
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 0, height: -10), backingScaleFactor: 2)

        #expect(resolution.width == DisplayBootSizing.minimumWidth)
        #expect(resolution.height == DisplayBootSizing.minimumHeight)
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

    @Test("doubled clamps at the pixel ceiling")
    func doubledClampsAtCeiling() {
        let large = DisplayBootSizing.Resolution(
            width: 5120, height: 4096, ppi: DisplayBootSizing.standardPixelsPerInch)

        let doubled = DisplayBootSizing.doubled(large)

        #expect(doubled.width == DisplayBootSizing.maximumDimension)
        #expect(doubled.height == DisplayBootSizing.maximumDimension)
    }

    @Test("halved clamps at the floor")
    func halvedClampsAtFloor() {
        let small = DisplayBootSizing.Resolution(
            width: 1000, height: 800, ppi: DisplayBootSizing.hiDPIPixelsPerInch)

        let halved = DisplayBootSizing.halved(small)

        #expect(halved.width == DisplayBootSizing.minimumWidth)
        #expect(halved.height == DisplayBootSizing.minimumHeight)
        #expect(halved.ppi == DisplayBootSizing.standardPixelsPerInch)
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

    // MARK: - Explicit clamping

    @Test("clamped honors a lowered ceiling for a size that will be doubled")
    func clampedHonorsLoweredCeiling() {
        let base = DisplayBootSizing.clamped(
            width: 6000, height: 5000, ppi: DisplayBootSizing.standardPixelsPerInch,
            maximum: DisplayBootSizing.maximumDimension / 2)

        #expect(base.width == DisplayBootSizing.maximumDimension / 2)
        #expect(base.height == DisplayBootSizing.maximumDimension / 2)
        // Doubling it lands exactly on the real ceiling.
        #expect(DisplayBootSizing.doubled(base).width == DisplayBootSizing.maximumDimension)
    }
}
