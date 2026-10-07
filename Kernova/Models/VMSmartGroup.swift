import Foundation
import KernovaKit

/// A named, saved library filter, which the sidebar lists as a section of its
/// own above the library.
///
/// Lives at library level, in ``VMOrganizationDirectory``. Its name is unique
/// in the library ignoring case; ``id`` is what everything keeping state about
/// the group — the sidebar's section, its collapse state — keys on, so a
/// rename moves none of it.
struct VMSmartGroup: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var name: String
    /// Which VMs the group lists; the default filter lists every VM.
    var filter: VMLibraryFilter
}

extension SidebarSectionID {
    private static let smartGroupPrefix = "smartGroup:"

    /// The section listing the smart group `id` identifies.
    static func smartGroup(_ id: UUID) -> SidebarSectionID {
        SidebarSectionID(rawValue: smartGroupPrefix + id.uuidString)
    }

    /// The smart group this section lists, `nil` for any other section.
    var smartGroupID: UUID? {
        guard rawValue.hasPrefix(Self.smartGroupPrefix) else { return nil }
        return UUID(uuidString: String(rawValue.dropFirst(Self.smartGroupPrefix.count)))
    }
}
