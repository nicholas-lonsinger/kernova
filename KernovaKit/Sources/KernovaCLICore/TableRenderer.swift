import Foundation
import KernovaKit

/// Column-aligned text for a person reading a terminal.
///
/// Two-space gutters and no borders, matching what the platform's own tools
/// print, so `awk`-style column extraction keeps working.
enum TableRenderer {
    /// A listing, one VM per line.
    ///
    /// Name first because that is what a person scans for, and the identifier
    /// last because it is 36 characters nobody reads unless two VMs share a
    /// name.
    ///
    /// `quiet` prints names alone — `.idOrName` accepts one back, so a name is
    /// what a shell loop feeds to the next command.
    static func render(_ rows: [VMSummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.name).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return columns(
            headings: ["NAME", "STATUS", "IP ADDRESS", "ID"],
            rows: rows.map {
                [
                    $0.name, VMStatus.displayName(forWireName: $0.status),
                    render($0.ipAddress), $0.id.uuidString,
                ]
            })
    }

    /// One VM's full description, as a field-per-line block.
    ///
    /// `quiet` prints the name alone, so the block never has to be parsed for
    /// the one field a script wanted.
    static func render(_ info: VMInfo, quiet: Bool) -> String {
        guard !quiet else { return info.name }
        var fields: [(String, String)] = [
            ("Name", info.name),
            ("Identifier", info.id.uuidString),
            ("Status", VMStatus.displayName(forWireName: info.status)),
            ("Guest", info.guestOS),
            ("CPUs", String(info.cpuCount)),
            ("Memory", memory(info.memoryBytes)),
            ("Disk", "\(info.diskSizeInGB) GB"),
            ("Network", info.networkMode ?? "Off"),
        ]
        if let mac = info.macAddress { fields.append(("MAC Address", mac)) }
        fields.append(("IP Address", render(info.ipAddress)))
        fields.append(contentsOf: [
            ("Guest Agent", info.agentStatus),
            ("Saved State", info.hasSavedState ? "Yes" : "No"),
            ("Ephemeral", info.isEphemeral ? "Yes" : "No"),
            ("Snapshots", String(info.snapshotCount)),
            ("Bundle", info.bundlePath),
        ])
        let width = fields.map(\.0.count).max() ?? 0
        return
            fields
            .map { "\(padded($0.0, to: width))  \($0.1)" }
            .joined(separator: "\n")
    }

    /// A VM's restore points, in the order the app listed them (newest first).
    ///
    /// The current snapshot carries a `*`, beside the name it marks rather than
    /// after the identifier nobody reads. `quiet` prints names alone, which is
    /// what the snapshot verbs accept back.
    static func render(_ rows: [SnapshotRow], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.snapshot.name).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return columns(
            headings: ["NAME", "CURRENT", "KIND", "TAKEN", "SIZE", "ID"],
            rows: rows.map {
                [
                    $0.snapshot.name, $0.snapshot.isCurrent ? "*" : "", $0.snapshot.kind,
                    taken($0.snapshot.createdAt), size($0.onDiskBytes),
                    $0.snapshot.id.uuidString,
                ]
            })
    }

    /// The folders a VM shares with its guest, in the order it carries them.
    ///
    /// `quiet` prints the paths alone, which is exactly what `share remove`
    /// takes back.
    public static func render(_ rows: [SharedDirectorySummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.path).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return columns(
            headings: ["PATH", "READ-ONLY"],
            rows: rows.map { [$0.path, $0.readOnly ? "Yes" : "No"] })
    }

    /// A VM's forwarded ports on one transport, in the order it carries them.
    ///
    /// The transport is the caller's filter rather than a column: `forward
    /// remove` names a rule by transport as well as by ports, so every line —
    /// under `quiet` above all — has to be one the same spelling of the verb
    /// takes back.
    public static func render(_ rules: [PortForwardingRule], quiet: Bool) -> String {
        guard !quiet else {
            return rules.map(PortMapping.text(for:)).joined(separator: "\n")
        }
        guard !rules.isEmpty else { return "" }
        return columns(headings: ["MAPPING"], rows: rules.map { [PortMapping.text(for: $0)] })
    }

    /// A virtual machine's settings, one per line, in the order they were
    /// asked for.
    ///
    /// `quiet` prints the values alone, which is what a script reading one
    /// setting wants — and a whole listing stays line-for-line alongside the
    /// keys that produced it.
    static func render(_ entries: [ConfigurationEntry], quiet: Bool) -> String {
        guard !quiet else { return entries.map(\.value).joined(separator: "\n") }
        guard !entries.isEmpty else { return "" }
        return columns(
            headings: ["KEY", "VALUE"], rows: entries.map { [$0.key, $0.value] })
    }

    /// The settings keyspace itself, one key per line.
    ///
    /// The gate is a column rather than a footnote: which settings a running
    /// guest still takes is the thing a person consults this listing for.
    /// `quiet` prints the names alone, which `get` and `set` both accept back.
    static func render(_ keys: [ConfigurationKeyDescriptor], quiet: Bool) -> String {
        guard !quiet else { return keys.map(\.name).joined(separator: "\n") }
        guard !keys.isEmpty else { return "" }
        return columns(
            headings: ["KEY", "WHILE RUNNING", "SUMMARY"],
            rows: keys.map {
                [$0.name, $0.editableWhileRunning ? "Yes" : "No", $0.summary]
            })
    }

    /// A guest address in the words this surface states it in.
    ///
    /// Each non-address case is a different answer to "what is its address",
    /// and collapsing them to a blank would lose the only useful part.
    static func render(_ address: GuestIPAddress) -> String {
        switch address {
        case .reserved(let value): value
        case .pending: "Pending"
        case .externallyAssigned: "Assigned by your network"
        case .unavailable: "None"
        }
    }

    /// When a capture was taken, in this Mac's own locale and time zone.
    private static func taken(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// What a snapshot's files occupy, in the unit Finder's Get Info would
    /// state it in, or `Unknown` for a snapshot the size read did not answer
    /// for.
    private static func size(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// Memory in the unit a person reads it in.
    private static func memory(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / Double(1 << 30)
        return gigabytes.rounded() == gigabytes
            ? "\(Int(gigabytes)) GB" : String(format: "%.1f GB", gigabytes)
    }

    /// `cell` widened to `width` characters.
    ///
    /// Appends spaces rather than calling `padding(toLength:withPad:startingAt:)`,
    /// which measures in UTF-16 units and *truncates* a cell longer than
    /// `width` in them. A path read off the disk is decomposed — `Café` arrives
    /// as `e` plus a combining acute — and an emoji is a surrogate pair, so
    /// either measures longer there than in the characters a column is sized
    /// by, and the cell would be cut to something no verb takes back.
    private static func padded(_ cell: String, to width: Int) -> String {
        cell + String(repeating: " ", count: width - cell.count)
    }

    /// `headings` over `rows`, every column padded to its widest cell.
    private static func columns(headings: [String], rows: [[String]]) -> String {
        let widths = headings.indices.map { column in
            max(headings[column].count, rows.map { $0[column].count }.max() ?? 0)
        }
        func line(_ cells: [String]) -> String {
            cells.indices
                .map { padded(cells[$0], to: widths[$0]) }
                .joined(separator: "  ")
                // The last column is padded like the others; trailing blanks
                // would make every line differ from what a reader copied.
                .trimmingCharacters(in: .whitespaces)
        }
        return ([line(headings)] + rows.map(line)).joined(separator: "\n")
    }
}
