import CoreGraphics

/// The on-screen area a VM's display is about to occupy.
struct DisplayBootSurface: Equatable, Sendable {
    /// Size of the area in points.
    var pointSize: CGSize
    /// Backing scale of the screen hosting it.
    var backingScaleFactor: CGFloat
}

/// Supplies the geometry a cold boot sizes the guest display to.
///
/// The window layer owns this: only it knows which window or screen a VM's
/// `displayPreference` resolves to.
@MainActor
protocol DisplayBootGeometryProviding: AnyObject {
    /// The surface `instance`'s display will fill, or `nil` when it can't be
    /// measured — the VM then boots at its persisted resolution.
    func displayBootSurface(for instance: VMInstance) -> DisplayBootSurface?
}
