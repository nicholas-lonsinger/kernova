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
    ///
    /// Kernova's own cap: VZ validates both display types at 16384/axis —
    /// measured 2026-08-01, see
    /// `docs/research/2026-08-01-vz-display-dimension-limits.md`.
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

    /// The boot resolution a "looks like" size of `width` × `height` produces
    /// at the density `hiDPI` names.
    ///
    /// The one place a chosen size becomes a stored trio: it fits the pair to
    /// the ceiling the density leaves — a HiDPI base is doubled before it
    /// reaches VZ, so it clamps to half of it — and doubles it from there.
    /// Twice any base is already even, so a HiDPI base keeps its own parity and
    /// halving the stored pixels gives it back exactly.
    static func resolution(base width: Int, height: Int, hiDPI: Bool) -> Resolution {
        guard hiDPI else {
            return clamped(width: width, height: height, ppi: standardPixelsPerInch)
        }
        let base = bounded(width: width, height: height, maximum: maximumDimension / 2)
        return Resolution(
            width: base.width * 2, height: base.height * 2, ppi: hiDPIPixelsPerInch)
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
    /// is raised to the minimum and rounded down to an even pixel count.
    static func clamped(width: Int, height: Int, ppi: Int) -> Resolution {
        let fitted = bounded(width: width, height: height, maximum: maximumDimension)
        return Resolution(width: even(fitted.width), height: even(fitted.height), ppi: ppi)
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

    /// `width`/`height` scaled down whole to fit `maximum`, then each axis
    /// held within the supported range.
    private static func bounded(width: Int, height: Int, maximum: Int)
        -> (width: Int, height: Int)
    {
        let fitted = scaledToFit(width: width, height: height, maximum: maximum)
        return (
            min(max(fitted.width, minimumWidth), maximum),
            min(max(fitted.height, minimumHeight), maximum)
        )
    }

    /// `value` rounded down to an even count; the bounds are even, so a value
    /// already within them stays within them.
    private static func even(_ value: Int) -> Int {
        value - abs(value % 2)
    }
}
