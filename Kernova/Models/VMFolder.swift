import Foundation

/// A hand-picked collection of the library's VMs, which the sidebar lists as
/// a section of its own, among the smart groups and the library.
///
/// Album-like: a VM can be in several folders, its bundle stays where it is,
/// and deleting a folder deletes none of its VMs. Lives at library level, in
/// ``VMOrganizationDirectory``, so a bundle carries none of it in or out.
/// Its name is unique among folders ignoring case; ``id`` is what the
/// sidebar's section and its collapse state key on.
struct VMFolder: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var name: String
    /// The library entries the folder holds, in the folder's own order — the
    /// one its section lists under the manual sort — each at most once.
    var members: [UUID]
}

extension SidebarSectionID {
    private static let folderPrefix = "folder:"

    /// The section listing the folder `id` identifies.
    static func folder(_ id: UUID) -> SidebarSectionID {
        SidebarSectionID(rawValue: folderPrefix + id.uuidString)
    }

    /// The folder this section lists, `nil` for any other section.
    var folderID: UUID? {
        guard rawValue.hasPrefix(Self.folderPrefix) else { return nil }
        return UUID(uuidString: String(rawValue.dropFirst(Self.folderPrefix.count)))
    }
}
