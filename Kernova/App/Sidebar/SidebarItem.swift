import Foundation

/// Singleton sentinel representing the "Virtual Machines" group row in the
/// sidebar's `NSOutlineView`.
///
/// `VMInstance` references are used directly as instance row items. The
/// outline view distinguishes the two by `===` identity, so the group needs
/// a stable object instance to compare against — `SidebarGroupItem.shared`.
@MainActor
final class SidebarGroupItem {
    static let shared = SidebarGroupItem()
    private init() {}
}
