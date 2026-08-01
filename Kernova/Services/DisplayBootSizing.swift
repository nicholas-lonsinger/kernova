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

    /// Smallest boot resolution offered, matching the display window's `minSize`.
    static let minimumWidth = 800
    static let minimumHeight = 600
    /// Largest pixel count in either axis.
    static let maximumDimension = 8192

    /// Density reported for a HiDPI ("Retina") guest display.
    static let hiDPIPixelsPerInch = 220
    /// Density reported for a 1× guest display.
    static let standardPixelsPerInch = 144
    /// Density at or above which a guest treats the display as HiDPI.
    static let hiDPIThreshold = 200

    static func isHiDPI(ppi: Int) -> Bool { ppi >= hiDPIThreshold }

    /// The boot resolution filling `points` on a screen of `scale`.
    ///
    /// Pass `scale` 1 for a guest whose scanout carries no density channel, so
    /// points and pixels stay 1:1.
    static func resolution(
        fittingPoints points: CGSize, backingScaleFactor scale: CGFloat
    ) -> Resolution {
        clamped(
            width: pixelCount(points.width, scale: scale),
            height: pixelCount(points.height, scale: scale),
            ppi: scale >= 2 ? hiDPIPixelsPerInch : standardPixelsPerInch)
    }

    /// `resolution` at twice the pixel count and HiDPI density — the rewrite
    /// that turns a "looks like" size into a Retina one.
    static func doubled(_ resolution: Resolution) -> Resolution {
        clamped(
            width: min(resolution.width, maximumDimension) * 2,
            height: min(resolution.height, maximumDimension) * 2,
            ppi: hiDPIPixelsPerInch)
    }

    /// `resolution` rewritten at the density `hiDPI` asks for, keeping the size
    /// it "looks like" unchanged.
    static func rescaled(_ resolution: Resolution, toHiDPI hiDPI: Bool) -> Resolution {
        hiDPI ? doubled(resolution) : halved(resolution)
    }

    /// `resolution` at half the pixel count and standard density.
    static func halved(_ resolution: Resolution) -> Resolution {
        clamped(
            width: resolution.width / 2, height: resolution.height / 2,
            ppi: standardPixelsPerInch)
    }

    /// `width`/`height` rounded down to even pixel counts and clamped into the
    /// supported range.
    ///
    /// `maximum` lowers the ceiling for a base ("looks like") size that will be
    /// doubled for HiDPI.
    static func clamped(
        width: Int, height: Int, ppi: Int, maximum: Int = maximumDimension
    ) -> Resolution {
        Resolution(
            width: clamp(width, minimum: minimumWidth, maximum: maximum),
            height: clamp(height, minimum: minimumHeight, maximum: maximum),
            ppi: ppi)
    }

    // MARK: - Private

    private static func pixelCount(_ points: CGFloat, scale: CGFloat) -> Int {
        let pixels = (points * scale).rounded(.down)
        guard pixels.isFinite, pixels > 0 else { return 0 }
        return Int(min(pixels, CGFloat(maximumDimension)))
    }

    private static func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
        let even = value - abs(value % 2)
        return min(max(even, minimum), maximum)
    }
}
