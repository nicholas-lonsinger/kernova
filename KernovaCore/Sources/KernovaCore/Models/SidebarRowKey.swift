import Foundation
import KernovaCommandModel

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

/// What a rename in the sidebar is open on.
package enum SidebarRename: Hashable, Sendable {
    /// The library entry `id` identifies, in its row.
    case entry(UUID)
    /// The smart group or folder `id` identifies, on its section's header.
    case group(VMGroupKind, UUID)
}

extension SidebarSectionID {
    /// The section listing the `kind` `id` identifies.
    package init(_ kind: VMGroupKind, _ id: UUID) {
        self = kind == .smartGroup ? .smartGroup(id) : .folder(id)
    }

    /// The smart group or folder this section lists, `nil` for any other
    /// section.
    package var group: (kind: VMGroupKind, id: UUID)? {
        if let id = smartGroupID { return (.smartGroup, id) }
        if let id = folderID { return (.folder, id) }
        return nil
    }
}
