import CoreGraphics
import Foundation

/// Pixel math for a VM's boot resolution: fitting a display to an on-screen
/// surface, and the HiDPI ⇄ standard rewrite the settings switch performs.
///
/// Pure and stateless; the values it returns are exactly what
/// ``ConfigurationBuilder`` hands to VZ.
struct DisplayBootSizing: Sendable {
    /// A boot resolution in pixels, with the density VZ reports to a macOS guest.
    struct Resolution: Equatable, Sendable {
        var width: Int
        var height: Int
        var ppi: Int
    }

    /// Smallest size in either axis — 1×1 validates for both VZ display types
    /// (`docs/research/2026-08-01-vz-display-dimension-limits.md`).
    ///
    /// There is no largest: `validate()` refuses an oversized display when the
    /// VM starts.
    static let minimumDimension = 1

    /// Density reported for a HiDPI ("Retina") guest display.
    static let hiDPIPixelsPerInch = 220
    /// Density reported for a 1× guest display.
    static let standardPixelsPerInch = 144
    /// Density at or above which a guest treats the display as HiDPI.
    static let hiDPIThreshold = 200

    static func isHiDPI(ppi: Int) -> Bool { ppi >= hiDPIThreshold }

    /// The "looks like" sizes a display at the density `hiDPI` names takes in
    /// either axis: from ``minimumDimension`` up to the largest whose pixel
    /// count an `Int` holds.
    static func baseBounds(hiDPI: Bool) -> InclusiveBounds<Int> {
        InclusiveBounds(lower: minimumDimension, upper: Int.max / scale(hiDPI: hiDPI))
    }

    /// The boot resolution filling `points` on a screen of `scale`.
    ///
    /// Pass `scale` 1 for a guest whose scanout carries no density channel, so
    /// points and pixels stay 1:1.
    static func resolution(
        fittingPoints points: CGSize, backingScaleFactor scale: CGFloat
    ) -> Resolution {
        let hiDPI = scale >= 2
        let factor = self.scale(hiDPI: hiDPI)
        return resolution(
            base: pixelCount(points.width, scale: scale) / factor,
            height: pixelCount(points.height, scale: scale) / factor,
            hiDPI: hiDPI)
    }

    /// The boot resolution a "looks like" size of `width` × `height` produces
    /// at the density `hiDPI` names.
    ///
    /// The one place a chosen size becomes a stored trio: it holds each axis
    /// within ``baseBounds(hiDPI:)`` and doubles a HiDPI base from there, so a
    /// HiDPI trio's pixels are always even and halving them gives the base back
    /// exactly.
    static func resolution(base width: Int, height: Int, hiDPI: Bool) -> Resolution {
        let bounds = baseBounds(hiDPI: hiDPI)
        let factor = scale(hiDPI: hiDPI)
        return Resolution(
            width: bounds.clamp(width) * factor, height: bounds.clamp(height) * factor,
            ppi: hiDPI ? hiDPIPixelsPerInch : standardPixelsPerInch)
    }

    /// `resolution` at twice the pixel count and HiDPI density — the rewrite
    /// that turns a "looks like" size into a Retina one.
    static func doubled(_ resolution: Resolution) -> Resolution {
        self.resolution(base: resolution.width, height: resolution.height, hiDPI: true)
    }

    /// `resolution` rewritten at the density `hiDPI` asks for, keeping the size
    /// it "looks like" unchanged.
    static func rescaled(_ resolution: Resolution, toHiDPI hiDPI: Bool) -> Resolution {
        hiDPI ? doubled(resolution) : halved(resolution)
    }

    /// `resolution` at half the pixel count and standard density.
    static func halved(_ resolution: Resolution) -> Resolution {
        self.resolution(base: resolution.width / 2, height: resolution.height / 2, hiDPI: false)
    }

    // MARK: - Private

    private static func scale(hiDPI: Bool) -> Int { hiDPI ? 2 : 1 }

    private static func pixelCount(_ points: CGFloat, scale: CGFloat) -> Int {
        let pixels = (points * scale).rounded(.down)
        guard pixels.isFinite, pixels > 0 else { return 0 }
        // Bounded only where the conversion would trap.
        return Int(min(pixels, CGFloat(Int32.max)))
    }
}
