import Foundation

/// What a configuration build produced for the session it brings up, besides
/// the machine itself: what ``VMActivity/adoptBuildProducts(_:_:)`` takes into
/// the session context.
///
/// `@unchecked Sendable`: built off the main actor and handed over whole —
/// nothing touches a pipe here until the session context adopts it.
struct VMSessionBuildProducts: @unchecked Sendable {
    let serialInputPipe: Pipe
    let serialOutputPipe: Pipe
    let clipboardInputPipe: Pipe?
    let clipboardOutputPipe: Pipe?
    /// `RemovableMediaDeviceInfo` for each item in `config.removableMedia`,
    /// attached on the XHCI controller at config-build time, under the UUIDs
    /// the live devices carry — so `instance.liveRemovableMedia` can locate
    /// them for hot-detach.
    let coldRemovableMedia: [RemovableMediaDeviceInfo]
    /// The share a one-device guest's automount device carries, `nil` when
    /// the configuration builds none.
    let directoryShare: MacOSDirectoryShare?
    /// The session's view of the vmnet networks the build's network attachment
    /// joins — the one the session's attachment recovery must classify and
    /// re-materialize through, and whose life holds the VM's own networks.
    let vmnetNetworks: VmnetSessionNetworks
}
