import Foundation

/// An order to list a library's VMs in. Each key has one fixed direction.
public enum VMLibrarySort: String, Codable, CaseIterable, Sendable {
    /// A→Z.
    case name
    /// Newest first.
    case dateCreated
    /// Most recent first: VMs live now, then by when each last ran, then
    /// those with no run recorded; ties A→Z.
    case lastRun
    /// The library's own order, or a folder's own for its members — the
    /// order dragging a sidebar row there changes.
    case manual

    /// What a person reads for this order.
    public var title: String {
        switch self {
        case .name: "Name"
        case .dateCreated: "Date Created"
        case .lastRun: "Last Run"
        case .manual: "Manual"
        }
    }

    /// What an order reads of one VM.
    public struct Keys: Sendable {
        /// The VM's display name.
        public var name: String
        /// When the VM was created.
        public var createdAt: Date
        /// When the VM last ran.
        public var lastRun: LastRun

        /// Keys reading as given.
        public init(name: String, createdAt: Date, lastRun: LastRun) {
            self.name = name
            self.createdAt = createdAt
            self.lastRun = lastRun
        }
    }

    /// When a VM last ran, as ``lastRun`` orders it.
    public enum LastRun: Sendable, Equatable {
        /// In a session, or held by another copy, which may be running it: its
        /// recorded run is then a session's start, not its end.
        case live
        /// Last ran at this moment.
        case ended(Date)
        /// No run recorded: never run, or last run only by a build that
        /// recorded none.
        case unrecorded
    }

    /// `elements`, given in their manual order, in this order; elements the
    /// key ties keep the manual order.
    public func ordered<Element>(_ elements: [Element], by keys: (Element) -> Keys) -> [Element] {
        guard self != .manual else { return elements }
        let keyed = elements.enumerated().map { (offset: $0.offset, keys: keys($0.element), element: $0.element) }
        return keyed.sorted { lhs, rhs in precedes(lhs.keys, rhs.keys) ?? (lhs.offset < rhs.offset) }
            .map(\.element)
    }

    /// Whether `lhs` comes first, `nil` where this key ties them.
    private func precedes(_ lhs: Keys, _ rhs: Keys) -> Bool? {
        switch self {
        case .manual:
            return nil
        case .name:
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return nil
            }
        case .dateCreated:
            return lhs.createdAt == rhs.createdAt ? nil : lhs.createdAt > rhs.createdAt
        case .lastRun:
            return Self.precedes(lhs.lastRun, rhs.lastRun) ?? Self.name.precedes(lhs, rhs)
        }
    }

    /// Whether `lhs` ran more recently, `nil` where they tie.
    private static func precedes(_ lhs: LastRun, _ rhs: LastRun) -> Bool? {
        switch (lhs, rhs) {
        case (.live, .live), (.unrecorded, .unrecorded): nil
        case (.live, _), (_, .unrecorded): true
        case (_, .live), (.unrecorded, _): false
        case (.ended(let lhs), .ended(let rhs)): lhs == rhs ? nil : lhs > rhs
        }
    }
}
