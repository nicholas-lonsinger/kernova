import Foundation

/// A sidebar section's identity, which is also its expansion-state key.
package struct SidebarSectionID: RawRepresentable, Hashable, Sendable, Codable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The section listing every library entry.
    package static let library = SidebarSectionID(rawValue: "virtualMachines")

    /// The section listed where the smart groups and folders go while they
    /// can't be read.
    static let unreadableOrganization = SidebarSectionID(rawValue: "unreadableOrganization")
}

/// A group header's identity within its section.
package struct SidebarGroupID: RawRepresentable, Hashable, Sendable, Codable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One sidebar row: a library entry as one section lists it, under one group
/// header or none.
///
/// A VM can be listed in several sections, and under several groups of one
/// section, so its identifier alone does not name a row.
package struct SidebarRowKey: Hashable, Sendable, Codable {
    package let section: SidebarSectionID
    package let group: SidebarGroupID?
    package let entryID: UUID

    /// The entry's row in the library section, outside any group.
    static func library(_ entryID: UUID) -> SidebarRowKey {
        SidebarRowKey(section: .library, group: nil, entryID: entryID)
    }
}
