import Foundation
import KernovaCommandModel

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
                    $0.name,
                    VMStatus.displayName(forWireName: $0.status, heldByAnotherCopy: $0.heldByAnotherCopy),
                    render($0.ipAddress), $0.id.uuidString,
                ]
            })
    }

    /// One VM's full description, as a field-per-line block.
    ///
    /// The disks are one field of a line per disk, in attachment order; the
    /// lines after the first start at the value column.
    static func render(_ report: VMInfoReport) -> String {
        var lines: [InfoRow: [String]] = [
            .disks: report.storageDisks.isEmpty ? ["\u{2013}"] : report.storageDisks.map(disk)
        ]
        for field in VMInfo.Field.allCases {
            guard let (row, rowLines) = row(showing: field, of: report.info) else { continue }
            lines[row] = rowLines
        }
        let fields = InfoRow.allCases.compactMap { row in lines[row].map { (row.rawValue, $0) } }
        let width = fields.map(\.0.count).max() ?? 0
        return
            fields
            .flatMap { key, lines in
                lines.enumerated().map { "\(padded($0.offset == 0 ? key : "", to: width))  \($0.element)" }
            }
            .joined(separator: "\n")
    }

    /// The rows of a VM's description, titled, in the order they print.
    private enum InfoRow: String, CaseIterable {
        case name = "Name"
        case identifier = "Identifier"
        case status = "Status"
        case guest = "Guest"
        case cpus = "CPUs"
        case memory = "Memory"
        case disks = "Disks"
        case network = "Network"
        case macAddress = "MAC Address"
        case ipAddress = "IP Address"
        case guestAgent = "Guest Agent"
        case agentVersion = "Agent Version"
        case savedState = "Saved State"
        case savedBy = "Saved By"
        case ephemeral = "Ephemeral"
        case snapshots = "Snapshots"
        case tags = "Tags"
        case bundle = "Bundle"
    }

    /// The row `field` of `info` prints, and its lines; `nil` for a field
    /// another row reads, or one with no value to print.
    private static func row(showing field: VMInfo.Field, of info: VMInfo) -> (InfoRow, [String])? {
        switch field {
        case .name: (.name, [info.name])
        case .id: (.identifier, [info.id.uuidString])
        case .status:
            (.status, [VMStatus.displayName(forWireName: info.status, heldByAnotherCopy: info.heldByAnotherCopy)])
        // Status reads it.
        case .heldByAnotherCopy: nil
        // Status names the state the group coarsens.
        case .stateBucket: nil
        case .guestOS: (.guest, [info.guestOS])
        case .cpuCount: (.cpus, [String(info.cpuCount)])
        case .memoryBytes: (.memory, [memory(info.memoryBytes)])
        case .networkMode:
            (
                .network,
                [
                    info.networkMode.map { mode in
                        [mode, info.networkName?.title ?? info.networkMembership].compactMap(\.self)
                            .joined(separator: ", ")
                    } ?? "Off"
                ]
            )
        // Network reads them beside the mode.
        case .networkMembership, .networkName: nil
        case .macAddress: info.macAddress.map { (.macAddress, [$0]) }
        case .ipAddress: (.ipAddress, [render(info.ipAddress)])
        case .agentStatus: (.guestAgent, [info.agentStatus ?? "\u{2013}"] + info.agents.map(render))
        // Guest Agent lists them under the status.
        case .agents: nil
        case .guestAgent: info.guestAgent.map { (.agentVersion, [$0.displayName]) }
        case .hasSavedState: (.savedState, [info.hasSavedState ? "Yes" : "No"])
        case .savedStateKernovaVersion: info.savedStateKernovaVersion.map { (.savedBy, ["Kernova \($0)"]) }
        case .isEphemeral: (.ephemeral, [info.isEphemeral ? "Yes" : "No"])
        case .snapshotCount: (.snapshots, [String(info.snapshotCount)])
        // Snapshots counts them.
        case .hasSnapshots: nil
        case .tags:
            (.tags, [info.tags.map { $0.isEmpty ? "\u{2013}" : $0.joined(separator: ", ") } ?? "Can\u{2019}t be read"])
        case .bundlePath: (.bundle, [info.bundlePath])
        }
    }

    /// One storage disk as its line of the `Disks` field: its label and
    /// capacity, then what it uses, its bus and its access where they say
    /// something.
    private static func disk(_ disk: StorageDiskSummary) -> String {
        var parts = ["\(disk.label): \(size(disk.capacityBytes))"]
        if let used = disk.usedBytes { parts.append("\(size(used)) used") }
        if disk.kind == "usbMassStorage" { parts.append("USB") }
        if disk.readOnly { parts.append("read-only") }
        return parts.joined(separator: ", ")
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
            headings: ["NAME", "CURRENT", "KIND", "TAKEN", "SIZE", "PRIVATE", "ID"],
            rows: rows.map {
                [
                    $0.snapshot.name, $0.snapshot.isCurrent ? "*" : "", $0.snapshot.kind,
                    taken($0.snapshot.createdAt), size($0.size?.bytes),
                    $0.size?.privateBytes.map(size) ?? "\u{2013}",
                    $0.snapshot.id.uuidString,
                ]
            })
    }

    /// The folders a VM shares with its guest, in the order it carries them.
    ///
    /// `quiet` prints the paths alone, which is exactly what `share remove`
    /// takes back.
    static func render(_ rows: [SharedDirectorySummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.path).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return columns(
            headings: ["PATH", "READ-ONLY"],
            rows: rows.map { [$0.path, $0.readOnly ? "Yes" : "No"] })
    }

    /// USB accessories, in the order Kernova was handed them.
    ///
    /// The two verbs name a row differently — an accessory is attached by its
    /// own identifier and detached by the attachment's — so the attachment
    /// column appears exactly when some row has one. On the accessories no
    /// guest holds it would be a column of nothing. `quiet` prints whichever
    /// identifier acts on that row.
    static func render(_ rows: [USBAccessorySummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(handle).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        guard rows.contains(where: { $0.deviceID != nil }) else {
            return columns(
                headings: ["NAME", "ACCESSORY"],
                rows: rows.map { [$0.name, String($0.registryID)] })
        }
        return columns(
            headings: ["NAME", "ACCESSORY", "DEVICE"],
            rows: rows.map { [$0.name, String($0.registryID), $0.deviceID?.uuidString ?? ""] })
    }

    /// The USB accessories virtual machines take back automatically.
    ///
    /// The virtual machine is a column rather than a grouping, because the
    /// listing with no machine named is the one this exists for: a key names at
    /// most one virtual machine, and which one is the answer being read off.
    /// `quiet` prints the key, which is what `usb forget` takes back.
    static func render(_ rows: [USBPairingSummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.key).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return columns(
            headings: ["VM", "NAME", "KEY"], rows: rows.map { [$0.vm, $0.name, $0.key] })
    }

    /// The library's named networks, in the order the app listed them (by
    /// name).
    ///
    /// The members are one comma-separated cell ahead of the identifier, so
    /// the identifier stays the last field however many names precede it.
    /// `quiet` prints names alone, which every `network` verb accepts back.
    static func render(_ rows: [NetworkSummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.name).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return columns(
            headings: ["NAME", "KIND", "MEMBERS", "ID"],
            rows: rows.map {
                [
                    $0.name, $0.kind.rawValue,
                    $0.members.isEmpty ? "None" : $0.members.map(\.name).joined(separator: ", "),
                    $0.id.uuidString,
                ]
            })
    }

    /// The library's groups, in the order the app listed them.
    ///
    /// Laid out as the named networks are. `quiet` prints names alone, which
    /// `list --smart-group` and `list --folder` accept back.
    static func render(_ rows: [GroupSummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.name).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return columns(
            headings: ["NAME", "KIND", "MEMBERS", "ID"],
            rows: rows.map {
                [
                    $0.name, $0.kind.rawValue,
                    $0.members.isEmpty ? "None" : $0.members.map(\.name).joined(separator: ", "),
                    $0.id.uuidString,
                ]
            })
    }

    /// What `usb attach` or `usb detach` takes back for one accessory: the
    /// attachment while a guest holds it, the accessory itself while none does.
    private static func handle(_ accessory: USBAccessorySummary) -> String {
        accessory.deviceID?.uuidString ?? String(accessory.registryID)
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
    /// Which settings a running guest still takes is a column rather than a
    /// footnote: it is the thing a person consults this listing for.
    /// `quiet` prints the names alone, which `get` and `set` both accept back.
    static func render(_ keys: [ConfigurationKeyDescriptor], quiet: Bool) -> String {
        guard !quiet else { return keys.map(\.name).joined(separator: "\n") }
        guard !keys.isEmpty else { return "" }
        return columns(
            headings: ["KEY", "WHILE RUNNING", "SUMMARY"],
            rows: keys.map {
                [$0.name, whileRunning($0.editableWhileRunning), $0.summary]
            })
    }

    /// Which guests a running VM takes a key on: "Yes" when every guest the
    /// key applies to does, "No" when none does, otherwise the ones that do.
    private static func whileRunning(_ byGuest: [String: Bool]) -> String {
        let taking = byGuest.filter(\.value).keys.sorted()
        if taking.count == byGuest.count { return "Yes" }
        if taking.isEmpty { return "No" }
        return taking.joined(separator: ", ") + " guests"
    }

    /// A guest address in the words this surface states it in.
    ///
    /// Each non-address case is a different answer to "what is its address",
    /// and collapsing them to a blank would lose the only useful part.
    static func render(_ address: GuestIPAddress) -> String {
        switch address {
        case .observed(let value): value
        case .notObserved: "Not seen"
        case .externallyAssigned: "Assigned by your network"
        case .unavailable: "None"
        }
    }

    /// When a capture was taken, in this Mac's own locale and time zone.
    private static func taken(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A size, in the unit Finder's Get Info would state it in, or `Unknown`
    /// for one the read did not answer for.
    private static func size(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// Memory in gigabytes, as every other surface and the `memory` key state it.
    private static func memory(_ bytes: UInt64) -> String {
        "\(VMMemorySize(roundingDown: bytes).gibibytesText) GB"
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

    /// One hub agent's line under the agent status: its title, then what
    /// ``part(showing:of:)`` shows of each field, in ``VMAgentLine/Field``
    /// order.
    private static func render(_ agent: VMAgentLine) -> String {
        let parts = VMAgentLine.Field.allCases.compactMap { part(showing: $0, of: agent) }
        return "\(agent.role.title(user: agent.user)): " + parts.joined(separator: ", ")
    }

    /// What an agent's line shows of `field`; `nil` for one its title reads,
    /// or one with no value to show.
    private static func part(showing field: VMAgentLine.Field, of agent: VMAgentLine) -> String? {
        switch field {
        case .role, .user: nil
        case .status: agent.status
        case .version: agent.version.isEmpty ? nil : agent.version
        }
    }
}
