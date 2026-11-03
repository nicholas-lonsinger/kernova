/// One install's root by path: its two slots, the `current` and `rollback` links, `state.json`, and the two
/// switch markers (``SlotRoot`` is the root open, as the agent and its rollback check change it).
public struct InstallRoot: Equatable, Sendable {
    /// The root's path.
    public let path: String

    /// The root at `path`.
    public init(path: String) {
        self.path = path
    }

    /// The directory the slots are in.
    public var slots: String { path + "/" + Self.slotsName }
    /// Slot `slot`.
    public func slot(_ slot: String) -> String { slots + "/" + slot }
    /// The link the service manager runs the agent through, to the slot in use.
    public var current: String { path + "/" + Self.currentLinkName }
    /// The link to the slot whose agent the rollback check runs: the one an update's switch left, or the one a
    /// fresh install landed.
    public var rollback: String { path + "/" + Self.rollbackLinkName }
    /// The slot metadata.
    public var state: String { path + "/" + Self.stateName }
    /// Present exactly while an update's switch is unconfirmed; the rollback check has work only then.
    public var switchPending: String { path + "/" + Self.switchPendingName }
    /// Present from the moment the rollback check reverts a switch until the agent it restarts records the
    /// switch's payload as rejected.
    public var switchRejected: String { path + "/" + Self.switchRejectedName }

    static let slotsName = "slots"
    /// The slot an install fills when `current` names none.
    public static let firstSlotName = "a"
    /// ``current``'s name in the root.
    public static let currentLinkName = "current"
    /// ``rollback``'s name in the root.
    public static let rollbackLinkName = "rollback"
    static let stateName = "state.json"
    /// ``switchPending``'s name in the root.
    public static let switchPendingName = "switch-pending"
    static let switchRejectedName = "switch-rejected"
}
