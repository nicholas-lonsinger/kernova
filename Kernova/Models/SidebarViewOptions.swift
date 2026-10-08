import Foundation
import KernovaKit

/// How the sidebar's library section narrows, orders and groups the library.
///
/// A projection only: the library's own order — ``VMLibrary/entries``, the
/// status menu, `kernova list` — stays the manual one whatever these say.
/// Persisted as ``AppPreferences/sidebarViewOptions``.
struct SidebarViewOptions: Codable, Hashable, Sendable {
    var filter = VMLibraryFilter()
    var sort: VMLibrarySort = .manual
    var grouping: SidebarGrouping = .none
    /// Whether each row carries a second line stating its sort key's value.
    var showsDetails = false

    /// One option set to a value, every other option left as it stands.
    enum Edit: Equatable, Sendable {
        case filter(VMLibraryFilter)
        case sort(VMLibrarySort)
        case grouping(SidebarGrouping)
        case showsDetails(Bool)
    }

    /// These options with `edit` made.
    func applying(_ edit: Edit) -> SidebarViewOptions {
        var edited = self
        switch edit {
        case .filter(let filter): edited.filter = filter
        case .sort(let sort): edited.sort = sort
        case .grouping(let grouping): edited.grouping = grouping
        case .showsDetails(let showsDetails): edited.showsDetails = showsDetails
        }
        return edited
    }
}

extension SidebarViewOptions {
    private enum CodingKeys: String, CodingKey {
        case filter, sort, grouping, showsDetails
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SidebarViewOptions()
        self.init(
            filter: try c.decodeIfPresent(VMLibraryFilter.self, forKey: .filter) ?? defaults.filter,
            sort: try c.decodeIfPresent(VMLibrarySort.self, forKey: .sort) ?? defaults.sort,
            grouping: try c.decodeIfPresent(SidebarGrouping.self, forKey: .grouping) ?? defaults.grouping,
            showsDetails: try c.decodeIfPresent(Bool.self, forKey: .showsDetails) ?? defaults.showsDetails)
    }
}

extension LibraryEntry {
    /// What a ``VMLibrarySort`` reads of this entry.
    var sortKeys: VMLibrarySort.Keys {
        VMLibrarySort.Keys(name: name, createdAt: configuration?.createdAt, lastRun: lastRun)
    }

    /// When this entry last ran: live while it is in a session, or held by
    /// another copy, which may be running it — ``VMHostState/lastRunAt`` then
    /// holds a session's start. An arrival, or a bundle Kernova can't read,
    /// has no run recorded.
    var lastRun: VMLibrarySort.LastRun {
        guard case .vm(let instance) = self else { return .unrecorded }
        switch instance.stateBucket {
        case .running, .heldByAnotherCopy: return .live
        case .stopped, .suspended, .preparing: return instance.hostState.lastRunAt.map { .ended($0) } ?? .unrecorded
        }
    }

    /// What a person reads for this entry's status.
    fileprivate var statusName: String {
        switch self {
        case .vm(let instance):
            instance.status.displayName(heldByAnotherCopy: instance.heldByAnotherCopy)
        case .arriving(let arrival):
            arrival.displayLabel
        case .unreadable:
            UnreadableVM.statusText
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
    /// relative to the present reads `now`, counting days in `calendar`.
    @MainActor
    func detail(
        for entry: LibraryEntry, at now: @autoclosure () -> Date, calendar: Calendar = .current
    ) -> String {
        switch self {
        case .name, .manual:
            entry.statusName
        case .dateCreated:
            entry.configuration.map {
                "Created \($0.createdAt.formatted(date: .abbreviated, time: .omitted))"
            } ?? entry.statusName
        case .lastRun:
            switch entry.lastRun {
            case .live:
                // A session settled running states when it started — not how
                // long it ran, which pauses and host sleep would overstate;
                // one starting, paused, or held by another copy states its
                // status.
                if case .vm(let instance) = entry, instance.status == .running,
                    let started = instance.sessionContext?.runningSince
                {
                    "Started \(Self.ago(started, now: now(), calendar: calendar))"
                } else {
                    entry.statusName
                }
            case .ended(let date):
                "Last run \(Self.ago(date, now: now(), calendar: calendar))"
            case .unrecorded:
                "No run recorded"
            }
        }
    }

    /// When `date` was, seen from `now`: "just now", then whole minutes or
    /// hours under a day, then calendar days in `calendar` — "yesterday",
    /// "3 days ago" — and the date itself from a week back.
    private static func ago(_ date: Date, now: Date, calendar: Calendar) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 60 else { return "just now" }
        let days =
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now))
            .day ?? 0
        // The day the clocks fall back runs 25 hours, so a run a full day
        // back can share today's date.
        guard elapsed >= 24 * 60 * 60, days >= 1 else {
            let units = Duration.seconds(Int(elapsed)).formatted(
                .units(
                    allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 1,
                    fractionalPart: .hide(rounded: .down)))
            return "\(units) ago"
        }
        switch days {
        case 1: return "yesterday"
        case 2...6: return "\(days) days ago"
        default:
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
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
