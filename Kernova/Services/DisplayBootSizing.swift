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

    /// Smallest boot resolution offered — guest desktops lay out badly below it.
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
        // Fitted before the doubling, so a corrupt stored size can't overflow it.
        let base = scaledToFit(
            width: resolution.width, height: resolution.height, maximum: maximumDimension / 2)
        return clamped(width: base.width * 2, height: base.height * 2, ppi: hiDPIPixelsPerInch)
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

    /// `width`/`height` brought into the supported range: an oversized pair is
    /// scaled down whole so its aspect ratio survives the ceiling, then each axis
    /// is rounded down to an even pixel count and raised to the minimum.
    ///
    /// `maximum` lowers the ceiling for a base ("looks like") size that will be
    /// doubled for HiDPI.
    static func clamped(
        width: Int, height: Int, ppi: Int, maximum: Int = maximumDimension
    ) -> Resolution {
        let fitted = scaledToFit(width: width, height: height, maximum: maximum)
        return Resolution(
            width: clamp(fitted.width, minimum: minimumWidth, maximum: maximum),
            height: clamp(fitted.height, minimum: minimumHeight, maximum: maximum),
            ppi: ppi)
    }

    // MARK: - Private

    /// `width`/`height` scaled by the longer axis' overshoot ratio when either
    /// exceeds `maximum`, leaving the pair's proportions intact.
    private static func scaledToFit(width: Int, height: Int, maximum: Int)
        -> (width: Int, height: Int)
    {
        let longest = max(width, height)
        guard longest > maximum else { return (width, height) }
        return (width * maximum / longest, height * maximum / longest)
    }

    private static func pixelCount(_ points: CGFloat, scale: CGFloat) -> Int {
        let pixels = (points * scale).rounded(.down)
        guard pixels.isFinite, pixels > 0 else { return 0 }
        // Bounded only where the conversion would trap: the pixel ceiling is
        // applied by `clamped`, which needs both axes' true proportions.
        return Int(min(pixels, CGFloat(Int32.max)))
    }

    private static func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
        let even = value - abs(value % 2)
        return min(max(even, minimum), maximum)
    }
}
