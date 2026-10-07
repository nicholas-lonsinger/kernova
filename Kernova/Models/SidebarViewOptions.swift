import Foundation
import KernovaKit

/// How the sidebar's library section narrows, orders and groups the library.
///
/// A projection only: the library's own order — ``VMLibrary/entries``, the
/// status menu, `kernova list` — stays the manual one whatever these say.
struct SidebarViewOptions: Codable, Hashable, Sendable {
    var filter = VMLibraryFilter()
    var sort: VMLibrarySort = .manual
    var grouping: SidebarGrouping = .none
    /// Whether each row carries a second line stating its sort key's value.
    var showsDetails = false
}

extension LibraryEntry {
    /// What a ``VMLibrarySort`` reads of this entry.
    var sortKeys: VMLibrarySort.Keys {
        VMLibrarySort.Keys(name: name, createdAt: configuration.createdAt, lastRun: lastRun)
    }

    /// When this entry last ran: live while a session is — here or in another
    /// copy — since ``VMHostState/lastRunAt`` then holds that session's start.
    /// An arrival has never run.
    var lastRun: VMLibrarySort.LastRun {
        guard case .vm(let instance) = self else { return .never }
        switch instance.stateBucket {
        case .running, .heldByAnotherCopy: return .live
        case .stopped, .suspended, .preparing: return instance.hostState.lastRunAt.map { .ended($0) } ?? .never
        }
    }

    /// What a person reads for this entry's status.
    fileprivate var statusName: String {
        switch self {
        case .vm(let instance):
            instance.status.displayName(heldByAnotherCopy: instance.heldByAnotherCopy)
        case .arriving(let arrival):
            arrival.displayLabel
        }
    }
}

extension VMLibrarySort {
    /// `entries` in this order; entries the key ties keep their manual order.
    @MainActor
    func ordered(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        ordered(entries, by: \.sortKeys)
    }

    /// The second line a row shows under this key: the value it is ordered by,
    /// or its status where the order is by name or by hand. Only a line stated
    /// relative to the present reads `now`.
    @MainActor
    func detail(for entry: LibraryEntry, at now: @autoclosure () -> Date) -> String {
        switch self {
        case .name, .manual:
            entry.statusName
        case .dateCreated:
            "Created \(entry.configuration.createdAt.formatted(date: .abbreviated, time: .omitted))"
        case .lastRun:
            switch entry.lastRun {
            case .live:
                // A session settled running states for how long; one starting,
                // paused, or held by another copy states its status.
                if case .vm(let instance) = entry, instance.status == .running,
                    let duration = instance.sessionRunningDuration(at: now())
                {
                    "Running for \(Self.runningDuration(duration))"
                } else {
                    entry.statusName
                }
            case .ended(let date):
                "Last run \(Self.relativeLastRun(date, now: now()))"
            case .never:
                "Never run"
            }
        }
    }

    /// `duration` down to its whole minute: "12 min", "1 hr, 5 min".
    private static func runningDuration(_ duration: TimeInterval) -> String {
        guard duration >= 60 else { return "under a minute" }
        return Duration.seconds(Int(duration)).formatted(
            .units(
                allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2,
                fractionalPart: .hide(rounded: .down)))
    }

    /// When `date` was, seen from `now`: relative within the past week
    /// ("yesterday", "3 hours ago"), the date itself before that.
    private static func relativeLastRun(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 60 else { return "just now" }
        guard elapsed < 7 * 24 * 60 * 60 else { return date.formatted(date: .abbreviated, time: .omitted) }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// The headers the library section lists its rows under.
enum SidebarGrouping: String, Codable, CaseIterable, Sendable {
    case none
    case guestOS
    case state
    case network
    case tag

    var title: String {
        switch self {
        case .none: "None"
        case .guestOS: "Guest OS"
        case .state: "State"
        case .network: "Network"
        case .tag: "Tag"
        }
    }
}
