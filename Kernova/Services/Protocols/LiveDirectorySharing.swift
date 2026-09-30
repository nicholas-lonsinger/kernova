import Foundation

/// A running macOS guest's directory-sharing device, as a live share swap
/// drives it.
@MainActor
protocol LiveDirectorySharing: AnyObject {
    /// Sets the share the device of the session `sessionID` names carries to
    /// `share`: `opened` — the scopes of the folders it newly carries — joins
    /// what that session holds, and the scope of each shared directory in
    /// `released` is let go once the device no longer carries it.
    ///
    /// When `sessionID` no longer names the live session, `opened` is released
    /// and nothing else happens.
    func install(
        _ share: MacOSDirectoryShare, holding opened: [UUID: ScopedAccess],
        releasing released: Set<UUID>, on instance: VMInstance, for sessionID: UUID)
}
