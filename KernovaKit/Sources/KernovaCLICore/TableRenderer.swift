import Foundation
import KernovaKit

/// Column-aligned text for a person reading a terminal.
///
/// Two-space gutters and no borders, matching what the platform's own tools
/// print, so `awk`-style column extraction keeps working.
public enum TableRenderer {
    /// A listing, one VM per line.
    ///
    /// `quiet` prints names alone — `.idOrName` accepts one back, so a name is
    /// what a shell loop feeds to the next command.
    public static func render(_ rows: [VMSummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.name).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return columns(
            headings: ["NAME", "STATUS", "ID"],
            rows: rows.map { [$0.name, VMStatus.displayName(forWireName: $0.status), $0.id.uuidString] })
    }

    /// One VM's full description, as a field-per-line block.
    ///
    /// `quiet` prints the name alone, so the block never has to be parsed for
    /// the one field a script wanted.
    public static func render(_ info: VMInfo, quiet: Bool) -> String {
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
            .map { "\($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
            .joined(separator: "\n")
    }

    /// A guest address in the words this surface states it in.
    ///
    /// Each non-address case is a different answer to "what is its address",
    /// and collapsing them to a blank would lose the only useful part.
    public static func render(_ address: GuestIPAddress) -> String {
        switch address {
        case .reserved(let value): value
        case .pending: "Pending"
        case .externallyAssigned: "Assigned by your network"
        case .unavailable: "None"
        }
    }

    /// Memory in the unit a person reads it in.
    private static func memory(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / Double(1 << 30)
        return gigabytes.rounded() == gigabytes
            ? "\(Int(gigabytes)) GB" : String(format: "%.1f GB", gigabytes)
    }

    /// `headings` over `rows`, every column padded to its widest cell.
    private static func columns(headings: [String], rows: [[String]]) -> String {
        let widths = headings.indices.map { column in
            max(headings[column].count, rows.map { $0[column].count }.max() ?? 0)
        }
        func line(_ cells: [String]) -> String {
            cells.indices
                .map { cells[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                // The last column is padded like the others; trailing blanks
                // would make every line differ from what a reader copied.
                .trimmingCharacters(in: .whitespaces)
        }
        return ([line(headings)] + rows.map(line)).joined(separator: "\n")
    }
}
