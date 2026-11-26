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
    /// last because it is 36 characters few read.
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
                    $0.status.displayName(heldByAnotherCopy: $0.heldByAnotherCopy),
                    render($0.ipAddress), $0.id.uuidString,
                ]
            })
    }

    /// One VM's full description, as a field-per-line block.
    ///
    /// The disks are one field of a line per disk, in attachment order; the
    /// lines after the first start at the value column.
    static func render(_ report: VMInfoReport) -> String {
        var lines = slots(of: VMInfo.Field.self) { row(showing: $0, of: report.info) }
        lines[.disks] = report.storageDisks.isEmpty ? ["\u{2013}"] : report.storageDisks.map(disk)
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
        case created = "Created"
        case lastRun = "Last Run"
        case bundle = "Bundle"
    }

    /// The row `field` of `info` prints, and its lines; `nil` for a field
    /// another row reads, or one with no value to print.
    private static func row(showing field: VMInfo.Field, of info: VMInfo) -> (InfoRow, [String])? {
        switch field {
        case .name: (.name, [info.name])
        case .id: (.identifier, [info.id.uuidString])
        case .status: (.status, [info.status.displayName(heldByAnotherCopy: info.heldByAnotherCopy)])
        // Status reads it.
        case .heldByAnotherCopy: nil
        // Status names the state the group coarsens.
        case .stateBucket: nil
        case .guestOS: (.guest, [info.guestOS.rawValue])
        case .cpuCount: (.cpus, [String(info.cpuCount)])
        case .memoryBytes: (.memory, [memory(info.memoryBytes)])
        case .networkMode:
            (
                .network,
                [
                    info.networkMode.map { mode in
                        [mode.rawValue, info.networkName?.title ?? info.networkMembership].compactMap(\.self)
                            .joined(separator: ", ")
                    } ?? "Off"
                ]
            )
        // Network reads them beside the mode.
        case .networkMembership, .networkName: nil
        case .macAddress: info.macAddress.map { (.macAddress, [$0]) }
        case .ipAddress: (.ipAddress, [render(info.ipAddress)])
        case .agentStatus: (.guestAgent, [info.agentStatus?.rawValue ?? "\u{2013}"] + info.agents.map(render))
        // Guest Agent lists them under the status.
        case .agents: nil
        case .guestAgent: info.guestAgent.map { (.agentVersion, [$0.displayName]) }
        case .hasSavedState: (.savedState, [info.hasSavedState ? "Yes" : "No"])
        case .savedStateKernovaVersion: info.savedStateKernovaVersion.map { (.savedBy, ["Kernova \($0)"]) }
        case .isEphemeral: (.ephemeral, [info.isEphemeral ? "Yes" : "No"])
        case .snapshotCount: (.snapshots, [String(info.snapshotCount)])
        // Snapshots counts them; for a VM a clone or import is still writing it
        // reads 0, as `snapshotCount` does, while this reads its source's.
        case .hasSnapshots: nil
        case .tags:
            (.tags, [info.tags.map { $0.isEmpty ? "\u{2013}" : $0.joined(separator: ", ") } ?? "Can\u{2019}t be read"])
        case .createdAt: (.created, [moment(info.createdAt)])
        case .lastRunAt: (.lastRun, [info.lastRunAt.map(moment) ?? "No run recorded"])
        case .bundlePath: (.bundle, [info.bundlePath])
        }
    }

    /// One storage disk as its line of the `Disks` field: its label, then
    /// what ``part(showing:of:)-(StorageDiskSummary.Field,_)`` shows of each
    /// field.
    private static func disk(_ disk: StorageDiskSummary) -> String {
        line(disk.label, slots(of: StorageDiskSummary.Field.self) { part(showing: $0, of: disk) })
    }

    /// The parts of a disk's line after its label, in the order they print.
    private enum DiskPart: CaseIterable {
        case capacity, used, bus, access
    }

    /// The part of its line `field` of `disk` fills, and its text; `nil` for
    /// a field the line leaves out, or one with nothing to say.
    private static func part(showing field: StorageDiskSummary.Field, of disk: StorageDiskSummary) -> (
        DiskPart, String
    )? {
        switch field {
        // The line opens with it.
        case .label: nil
        case .capacityBytes: (.capacity, size(disk.capacityBytes))
        case .usedBytes: disk.usedBytes.map { (.used, "\(size($0)) used") }
        case .kind: disk.kind == .usbMassStorage ? (.bus, "USB") : nil
        case .readOnly: disk.readOnly ? (.access, "read-only") : nil
        // No `kernova` command takes a disk by its identifier.
        case .id: nil
        // The line names the disk by its label; the JSON gives its image's path.
        case .path: nil
        // Free text, possibly several lines, which one line per disk can't hold.
        case .notes: nil
        }
    }

    /// A VM's restore points, in the order the app listed them (newest first).
    ///
    /// The current snapshot carries a `*`, beside the name it marks rather than
    /// after the identifier nobody reads. `quiet` prints names alone, which is
    /// what the snapshot verbs accept back.
    static func render(_ rows: [SnapshotRow], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.snapshot.name).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return table(
            rows, of: SnapshotSummary.Field.self,
            extra: { [.size: size($0.size?.bytes), .private: $0.size?.privateBytes.map(size) ?? "\u{2013}"] }
        ) { column(showing: $0, of: $1.snapshot) }
    }

    /// The columns of a snapshot listing, headed, in the order they print.
    private enum SnapshotColumn: String, CaseIterable {
        case name = "NAME"
        case current = "CURRENT"
        case kind = "KIND"
        case taken = "TAKEN"
        case size = "SIZE"
        case `private` = "PRIVATE"
        case id = "ID"
    }

    /// The column `field` of `snapshot` fills, and its cell; `nil` for a field
    /// the listing leaves out.
    private static func column(showing field: SnapshotSummary.Field, of snapshot: SnapshotSummary) -> (
        SnapshotColumn, String
    )? {
        switch field {
        case .name: (.name, snapshot.name)
        case .isCurrent: (.current, snapshot.isCurrent ? "*" : "")
        case .kind: (.kind, snapshot.kind.rawValue)
        case .createdAt: (.taken, moment(snapshot.createdAt))
        case .id: (.id, snapshot.id.uuidString)
        // Free text, possibly several lines, which a row can't hold.
        case .notes: nil
        // `kernova get <vm> ephemeral.baseline` names it, by the identifier ID shows.
        case .isEphemeralBaseline: nil
        }
    }

    /// The folders a VM shares with its guest, in the order it carries them.
    ///
    /// `quiet` prints the paths alone, which is exactly what `share remove`
    /// takes back.
    static func render(_ rows: [SharedDirectorySummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.path).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return table(rows, of: SharedDirectorySummary.Field.self) { field, share in
            switch field {
            case .name: (ShareColumn.name, share.name)
            case .path: (.path, share.path)
            case .readOnly: (.readOnly, share.readOnly ? "Yes" : "No")
            }
        }
    }

    /// The columns of a share listing, headed, in the order they print.
    private enum ShareColumn: String, CaseIterable {
        case name = "NAME"
        case path = "PATH"
        case readOnly = "READ-ONLY"
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
        let shown: [USBAccessoryColumn] =
            rows.contains { $0.deviceID != nil } ? USBAccessoryColumn.allCases : [.name, .accessory]
        return table(rows, of: USBAccessorySummary.Field.self, columns: shown) { field, accessory in
            switch field {
            case .name: (USBAccessoryColumn.name, accessory.name)
            case .registryID: (.accessory, String(accessory.registryID))
            case .deviceID: accessory.deviceID.map { (.device, $0.uuidString) }
            // The name is made of them for an accessory that reports no name of its own.
            case .vendorID, .productID: nil
            // `usb rules` prints it, for an accessory a virtual machine takes back.
            case .key: nil
            }
        }
    }

    /// The columns of an accessory listing, headed, in the order they print.
    private enum USBAccessoryColumn: String, CaseIterable {
        case name = "NAME"
        case accessory = "ACCESSORY"
        case device = "DEVICE"
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
        return table(rows, of: USBPairingSummary.Field.self) { field, pairing in
            switch field {
            case .vm: (PairingColumn.vm, pairing.vm)
            case .name: (.name, pairing.name)
            case .key: (.key, pairing.key)
            // The listing is read for which virtual machine a key names; the
            // JSON gives when the accessory was remembered.
            case .pairedAt: nil
            }
        }
    }

    /// The columns of a remembered-accessory listing, headed, in the order
    /// they print.
    private enum PairingColumn: String, CaseIterable {
        case vm = "VM"
        case name = "NAME"
        case key = "KEY"
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
        return table(rows, of: NetworkSummary.Field.self) { field, network in
            switch field {
            case .name: (MembersColumn.name, network.name)
            case .kind: (.kind, network.kind.rawValue)
            case .members: (.members, memberNames(network.members))
            case .id: (.id, network.id.uuidString)
            }
        }
    }

    /// The library's groups, in the order the app listed them.
    ///
    /// Laid out as the named networks are. `quiet` prints names alone, which
    /// `list --smart-group` and `list --folder` accept back.
    static func render(_ rows: [GroupSummary], quiet: Bool) -> String {
        guard !quiet else { return rows.map(\.name).joined(separator: "\n") }
        guard !rows.isEmpty else { return "" }
        return table(rows, of: GroupSummary.Field.self) { field, group in
            switch field {
            case .name: (MembersColumn.name, group.name)
            case .kind: (.kind, group.kind.rawValue)
            case .members: (.members, memberNames(group.members))
            case .id: (.id, group.id.uuidString)
            }
        }
    }

    /// The columns of a network or group listing, headed, in the order they
    /// print: the members one comma-separated cell ahead of the identifier.
    private enum MembersColumn: String, CaseIterable {
        case name = "NAME"
        case kind = "KIND"
        case members = "MEMBERS"
        case id = "ID"
    }

    /// The members cell of a network or group listing.
    private static func memberNames(_ members: [VMSummary]) -> String {
        members.isEmpty ? "None" : members.map(\.name).joined(separator: ", ")
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

    /// A moment, in this Mac's own locale and time zone.
    private static func moment(_ date: Date) -> String {
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

    /// One hub agent's line under the agent status: which agent, then what
    /// ``part(showing:of:)-(VMAgentLine.Field,_)`` shows of each field.
    private static func render(_ agent: VMAgentLine) -> String {
        line(agent.role.title(user: agent.user), slots(of: VMAgentLine.Field.self) { part(showing: $0, of: agent) })
    }

    /// The parts of an agent's line after which agent it is, in the order they
    /// print.
    private enum AgentPart: CaseIterable {
        case status, version
    }

    /// The part of its line `field` of `agent` fills, and its text; `nil` for
    /// a field the line opens with, or one with nothing to say.
    private static func part(showing field: VMAgentLine.Field, of agent: VMAgentLine) -> (AgentPart, String)? {
        switch field {
        case .role, .user: nil
        case .status: (.status, agent.status.rawValue)
        case .version: agent.version.isEmpty ? nil : (.version, agent.version)
        }
    }

    // MARK: - Accounted fields

    /// What `cell` puts in each slot over every case of `Field`.
    private static func slots<Field: CaseIterable, Slot: Hashable, Value>(
        of _: Field.Type, _ cell: (Field) -> (Slot, Value)?
    ) -> [Slot: Value] {
        var slots: [Slot: Value] = [:]
        for field in Field.allCases {
            if let (slot, value) = cell(field) { slots[slot] = value }
        }
        return slots
    }

    /// `rows` under `shown` as headings — every case of `Column` unless
    /// narrowed — each cell what `cell` puts in that column for one of
    /// `Field`'s cases, or what `extra` does.
    private static func table<Row, Field: CaseIterable, Column: CaseIterable & Hashable & RawRepresentable>(
        _ rows: [Row], of field: Field.Type, columns shown: [Column] = Array(Column.allCases),
        extra: (Row) -> [Column: String] = { _ in [:] }, _ cell: (Field, Row) -> (Column, String)?
    ) -> String where Column.RawValue == String {
        columns(
            headings: shown.map(\.rawValue),
            rows: rows.map { row in
                let cells = slots(of: field) { cell($0, row) }.merging(extra(row)) { accounted, _ in accounted }
                return shown.map { cells[$0] ?? "" }
            })
    }

    /// `title`, then the parts `parts` fills, in `Part`'s order.
    private static func line<Part: CaseIterable & Hashable>(_ title: String, _ parts: [Part: String]) -> String {
        "\(title): " + Part.allCases.compactMap { parts[$0] }.joined(separator: ", ")
    }
}
