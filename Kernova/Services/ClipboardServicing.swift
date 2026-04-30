import Foundation

/// Common surface shared by every clipboard transport.
///
/// Two implementations exist:
/// - `SpiceClipboardService` — Linux guests, runs the SPICE agent protocol over a
///   `VZVirtioConsolePortConfiguration`-backed pipe pair.
/// - `VsockClipboardService` — macOS guests, runs the Kernova clipboard protocol
///   over a `VZVirtioSocketDevice`-backed `VsockChannel`.
///
/// Both implementations are `@Observable` classes so consumers can observe
/// `clipboardText` and `isConnected` through the existential type without losing
/// SwiftUI / `withObservationTracking` integration: the `@Observable` macro
/// installs the registrar on the concrete type, so reading or writing through
/// the protocol witness still fires observation.
@MainActor
protocol ClipboardServicing: AnyObject {

    /// Bidirectional clipboard buffer. Set by the user (via the clipboard window)
    /// to seed an outbound grab; updated by the implementation when the guest
    /// pushes new content.
    var clipboardText: String { get set }

    /// `true` once the implementation has completed its handshake with the guest.
    var isConnected: Bool { get }

    /// Begins protocol I/O with the guest.
    func start()

    /// Stops protocol I/O. Idempotent.
    func stop()

    /// Announces the current `clipboardText` to the guest if it has changed since
    /// the last successful announcement. Called by the clipboard window when it
    /// loses focus.
    func grabIfChanged()
}
