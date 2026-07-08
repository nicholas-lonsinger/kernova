import Foundation
import os

/// Resolves the shared app group identifier from the running executable's
/// Info.plist.
///
/// The identifier is per-build-configuration, carried by the `KERNOVA_APP_GROUP`
/// build setting that every target substitutes into its Info.plist: Debug uses a
/// Team-ID-prefixed group (`$(DEVELOPMENT_TEAM).app.kernova`) that macOS grants
/// silent container access to with no provisioning profile (macOS 15 app-group
/// protection, criterion C), and Release uses the canonical `group.app.kernova`.
/// KernovaKit is a SwiftPM package and cannot read Xcode build settings, so each
/// executable (app, agent, or File Provider extension) records its resolved value
/// in the `KernovaAppGroup` Info.plist key and this helper reads it back at
/// runtime.
public enum KernovaAppGroup {
    /// Info.plist key each target populates with `$(KERNOVA_APP_GROUP)`.
    public static let infoPlistKey = "KernovaAppGroup"

    private static let logger = Logger(subsystem: "app.kernova", category: "AppGroup")

    /// The app group identifier resolved from `bundle`.
    ///
    /// - Parameter bundle: the bundle whose Info.plist is read; defaults to the
    ///   main bundle (the running executable).
    /// - Returns: the configured identifier, or the canonical Release value as a
    ///   graceful fallback if the key is missing — which should never happen in a
    ///   correctly built target, so it also asserts in Debug.
    public static func identifier(from bundle: Bundle = .main) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
            !value.isEmpty
        else {
            logger.fault(
                "Info.plist key '\(infoPlistKey, privacy: .public)' missing or empty; falling back to canonical app group"
            )
            assertionFailure("Info.plist key '\(infoPlistKey)' missing or empty")
            return "group.app.kernova"
        }
        return value
    }
}
