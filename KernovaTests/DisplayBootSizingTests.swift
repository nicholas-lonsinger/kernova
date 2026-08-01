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

    @Test("A surface above the ceiling scales down whole, keeping its shape")
    func clampsDownToCeiling() {
        // 6000 × 5000 points at 2× is 12000 × 10000 pixels; × 8192/12000 fits
        // the ceiling without squaring the 6:5 pair off against it.
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: CGSize(width: 6000, height: 5000), backingScaleFactor: 2)

        #expect(resolution.width == DisplayBootSizing.maximumDimension)
        #expect(resolution.height == 6826)
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

    @Test("A double that overflows the ceiling keeps its shape through the round-trip")
    func doubledPreservesAspectAtCeiling() {
        let base = DisplayBootSizing.Resolution(
            width: 6000, height: 5000, ppi: DisplayBootSizing.standardPixelsPerInch)
        let ratio = Double(base.width) / Double(base.height)

        // 12000 × 10000 scaled by 8192/12000 — not squared off at 8192 × 8192.
        let retina = DisplayBootSizing.doubled(base)
        #expect(
            retina
                == DisplayBootSizing.Resolution(
                    width: DisplayBootSizing.maximumDimension, height: 6826,
                    ppi: DisplayBootSizing.hiDPIPixelsPerInch))
        #expect(abs(Double(retina.width) / Double(retina.height) - ratio) < 0.001)

        let standard = DisplayBootSizing.halved(retina)
        #expect(abs(Double(standard.width) / Double(standard.height) - ratio) < 0.001)
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
        #expect(base.height == 3412)
        // Doubling it lands exactly on the real ceiling.
        #expect(DisplayBootSizing.doubled(base).width == DisplayBootSizing.maximumDimension)
    }
}
