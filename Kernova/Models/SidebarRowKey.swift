import Foundation

/// A sidebar section's identity, which is also its expansion-state key.
struct SidebarSectionID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The section listing every library entry.
    static let library = SidebarSectionID(rawValue: "virtualMachines")
}

/// A group header's identity within its section.
struct SidebarGroupID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One sidebar row: a library entry as one section lists it, under one group
/// header or none.
///
/// A VM can be listed in several sections, and under several groups of one
/// section, so its identifier alone does not name a row.
struct SidebarRowKey: Hashable, Sendable, Codable {
    let section: SidebarSectionID
    let group: SidebarGroupID?
    let entryID: UUID

    /// The entry's row in the library section, outside any group.
    static func library(_ entryID: UUID) -> SidebarRowKey {
        SidebarRowKey(section: .library, group: nil, entryID: entryID)
    }
}
