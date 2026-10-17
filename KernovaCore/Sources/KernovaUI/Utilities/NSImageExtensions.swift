import Cocoa
import KernovaLogging

extension NSImage {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "NSImage")

    /// Returns a system symbol image, or a zero-size fallback if the symbol is not found.
    ///
    /// A missing symbol logs at `.fault` level and triggers `assertionFailure` in debug builds,
    /// since symbol names are compile-time constants and a lookup failure indicates a typo or
    /// deployment-target mismatch.
    static func systemSymbol(_ name: String, accessibilityDescription: String) -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) else {
            #log(logger, .fault, "Failed to load system symbol '\(name, privacy: .public)'")
            assertionFailure("Missing SF Symbol: \(name)")
            return NSImage()
        }
        return image
    }
}
