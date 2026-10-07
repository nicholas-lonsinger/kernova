import Foundation

/// An order to list a library's VMs in. Each key has one fixed direction.
public enum VMLibrarySort: String, Codable, CaseIterable, Sendable {
    /// A→Z.
    case name
    /// Newest first.
    case dateCreated
    /// The library's own order, or a folder's own for its members — the
    /// order dragging a sidebar row there changes.
    case manual

    /// What a person reads for this order.
    public var title: String {
        switch self {
        case .name: "Name"
        case .dateCreated: "Date Created"
        case .manual: "Manual"
        }
    }

    /// What an order reads of one VM.
    public struct Keys: Sendable {
        /// The VM's display name.
        public var name: String
        /// When the VM was created.
        public var createdAt: Date

        /// Keys reading as given.
        public init(name: String, createdAt: Date) {
            self.name = name
            self.createdAt = createdAt
        }
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
        }
    }
}
