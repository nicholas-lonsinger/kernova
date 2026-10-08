import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// What the tool prints, for a person and for a script.
@Suite("CLI rendering", .caseScoped)
struct CLIRenderingTests {
    private let alpha = VMSummary(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
        name: "Alpha", status: "running", ipAddress: .observed("192.168.64.4"), heldByAnotherCopy: false)
    private let longName = VMSummary(
        id: UUID(uuidString: "66666666-7777-8888-9999-000000000000") ?? UUID(),
        name: "A Much Longer Name", status: "initialBoot", ipAddress: .notObserved, heldByAnotherCopy: false)

    private func info(
        ipAddress: GuestIPAddress = .observed("192.168.64.4"), memoryBytes: UInt64 = 8 << 30,
        networkMembership: String = "common", networkName: VMNetworkName? = nil
    ) -> VMInfo {
        VMInfo(
            id: alpha.id, name: "Alpha", status: "running", guestOS: "macOS", cpuCount: 4,
            memoryBytes: memoryBytes, diskSizeInGB: 64, networkMode: "shared", networkMembership: networkMembership,
            networkName: networkName, macAddress: "aa:bb:cc:dd:ee:ff",
            ipAddress: ipAddress, agentStatus: "current",
            hasSavedState: false, isEphemeral: true, snapshotCount: 2, hasSnapshots: false, guestAgent: nil,
            stateBucket: .stopped,
            bundlePath: "/Users/somebody/VMs/Alpha.kernova", heldByAnotherCopy: false)
    }

    // MARK: - Listing

    @Test("A listing's columns align to the widest cell, and headings name them")
    func listingColumnsAlign() {
        let lines = TableRenderer.render([alpha, longName], quiet: false)
            .components(separatedBy: "\n")

        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("NAME"))
        // The second column starts at the same offset on every line, which is
        // the whole point of padding to the widest cell.
        let starts = lines.map { line -> Int in
            let name = line.hasPrefix("NAME") ? "STATUS" : (line.hasPrefix("Alpha") ? "Running" : "Initial Boot")
            guard let range = line.range(of: name) else { return -1 }
            return line.distance(from: line.startIndex, to: range.lowerBound)
        }
        #expect(Set(starts).count == 1)
        #expect(starts[0] > 0)
        #expect(lines[1].contains("Running"))
        // The wire's `initialBoot` reaches a person as words, never raw.
        #expect(lines[2].contains("Initial Boot"))
        #expect(!lines[2].contains("initialBoot"))
    }

    @Test("A listing ends every line with content, never with padding")
    func listingHasNoTrailingBlanks() {
        for line in TableRenderer.render([alpha, longName], quiet: false)
            .components(separatedBy: "\n")
        {
            #expect(line == line.trimmingCharacters(in: .whitespaces))
        }
    }

    @Test("A listing names every field #309 asks for: name, state, address, identifier")
    func listingCarriesEveryField() {
        let lines = TableRenderer.render([alpha, longName], quiet: false)
            .components(separatedBy: "\n")

        #expect(lines[0].contains("NAME"))
        #expect(lines[0].contains("STATUS"))
        #expect(lines[0].contains("IP ADDRESS"))
        #expect(lines[0].contains("ID"))
        // Each address reads the way `info` states it, per case.
        #expect(lines[1].contains("192.168.64.4"))
        #expect(lines[1].contains(alpha.id.uuidString))
        #expect(lines[2].contains("Not seen"))
    }

    @Test("A VM another copy holds reads as in use by it, in the listing and in info")
    func heldByAnotherCopyReplacesTheStatus() throws {
        let held = VMSummary(
            id: alpha.id, name: "Alpha", status: "stopped", ipAddress: .notObserved,
            heldByAnotherCopy: true)
        let listing = TableRenderer.render([held], quiet: false).components(separatedBy: "\n")
        #expect(listing[1].contains("In use by another copy of Kernova"))
        #expect(!listing[1].contains("Stopped"))

        let base = info()
        let heldInfo = VMInfo(
            id: base.id, name: base.name, status: "stopped", guestOS: base.guestOS,
            cpuCount: base.cpuCount, memoryBytes: base.memoryBytes, diskSizeInGB: base.diskSizeInGB,
            networkMode: base.networkMode, networkMembership: base.networkMembership, networkName: nil,
            macAddress: base.macAddress, ipAddress: .notObserved,
            agentStatus: base.agentStatus, hasSavedState: false, isEphemeral: base.isEphemeral,
            snapshotCount: base.snapshotCount, hasSnapshots: base.hasSnapshots, guestAgent: base.guestAgent,
            stateBucket: .heldByAnotherCopy,
            bundlePath: base.bundlePath, heldByAnotherCopy: true)
        let status = try #require(
            TableRenderer.render(heldInfo, quiet: false).components(separatedBy: "\n")
                .first { $0.hasPrefix("Status") })
        #expect(status.hasSuffix("In use by another copy of Kernova"))

        // A script reads the field itself.
        let decoded = try JSONDecoder().decode(
            VMSummary.self, from: try JSONEncoder().encode(held))
        #expect(decoded.heldByAnotherCopy)
    }

    @Test("--quiet prints names alone, one per line")
    func quietListingIsNamesOnly() {
        #expect(
            TableRenderer.render([alpha, longName], quiet: true) == "Alpha\nA Much Longer Name")
    }

    @Test("An empty library prints nothing at all")
    func emptyListingIsEmpty() {
        #expect(TableRenderer.render([VMSummary](), quiet: false).isEmpty)
        #expect(TableRenderer.render([VMSummary](), quiet: true).isEmpty)
    }

    // MARK: - Info

    @Test("An info block names every field, and reads the status in words")
    func infoNamesEveryField() {
        let rendered = TableRenderer.render(info(), quiet: false)

        for field in [
            "Name", "Identifier", "Status", "Guest", "CPUs", "Memory", "Disk", "Network",
            "MAC Address", "IP Address", "Guest Agent", "Saved State", "Ephemeral", "Snapshots",
            "Bundle",
        ] {
            #expect(rendered.contains(field), "missing \(field)")
        }
        #expect(rendered.contains("Running"))
        #expect(rendered.contains("8 GB"))
        #expect(rendered.contains("192.168.64.4"))
    }

    @Test("A named network whose name the unreadable list can't give reads as that, not as its identifier")
    func anUnreadableNetworkNameReadsAsSuch() throws {
        let id = "6A1F0B2C-3D4E-4F50-8A6B-7C8D9E0F1A2B"
        let rendered = TableRenderer.render(
            info(networkMembership: id, networkName: .unreadable), quiet: false)
        let network = try #require(rendered.components(separatedBy: "\n").first { $0.hasPrefix("Network") })

        #expect(network.hasSuffix("shared, Network List Can\u{2019}t Be Read"))
        #expect(!rendered.contains(id))
    }

    @Test("A named network the library does not list reads as its identifier")
    func anUnlistedNetworkReadsAsItsIdentifier() throws {
        let id = try #require(UUID(uuidString: "6A1F0B2C-3D4E-4F50-8A6B-7C8D9E0F1A2B"))
        let rendered = TableRenderer.render(
            info(networkMembership: id.uuidString, networkName: .unlisted(id)), quiet: false)
        let network = try #require(rendered.components(separatedBy: "\n").first { $0.hasPrefix("Network") })

        #expect(network.hasSuffix("shared, \(id.uuidString)"))
    }

    @Test("Memory reads in the gigabytes the memory key takes, to the megabyte")
    func infoStatesMemoryAsTheKeyDoes() throws {
        let memory = { (bytes: UInt64) throws -> String in
            try #require(
                TableRenderer.render(self.info(memoryBytes: bytes), quiet: false)
                    .components(separatedBy: "\n").first { $0.hasPrefix("Memory") })
        }
        #expect(try memory(1536 << 20).hasSuffix(" 1.5 GB"))
        #expect(try memory(1537 << 20).hasSuffix(" 1.501 GB"))
        #expect(try memory(8 << 30).hasSuffix(" 8 GB"))
    }

    @Test("--quiet on info prints the name alone")
    func quietInfoIsTheNameAlone() {
        #expect(TableRenderer.render(info(), quiet: true) == "Alpha")
    }

    // MARK: - Snapshots

    private let taken = Date(timeIntervalSince1970: 1_770_000_000)

    private func snapshot(
        name: String, id: UUID = UUID(), isCurrent: Bool = false, kind: String = "warm"
    ) -> SnapshotSummary {
        SnapshotSummary(
            id: id, name: name, notes: "", kind: kind, createdAt: taken, isCurrent: isCurrent,
            isEphemeralBaseline: false)
    }

    @Test("A snapshot listing names every column #309 asks for, and marks the current one")
    func snapshotListingCarriesEveryColumn() {
        let rows = [
            SnapshotRow(
                snapshot(name: "Base", isCurrent: true),
                size: SnapshotSize(bytes: 1_500_000_000, privateBytes: 200_000_000)),
            SnapshotRow(
                snapshot(name: "Before Upgrade", kind: "cold"),
                size: SnapshotSize(bytes: 0, privateBytes: nil)),
        ]
        let lines = TableRenderer.render(rows, quiet: false).components(separatedBy: "\n")

        #expect(lines.count == 3)
        for heading in ["NAME", "CURRENT", "KIND", "TAKEN", "SIZE", "PRIVATE", "ID"] {
            #expect(lines[0].contains(heading), "missing \(heading)")
        }
        #expect(lines[1].contains("Base"))
        #expect(lines[1].contains("warm"))
        #expect(lines[2].contains("cold"))
        #expect(
            lines[1].contains(
                ByteCountFormatter.string(fromByteCount: 200_000_000, countStyle: .file)))
        // No private bytes — a volume that can't clone — reads as a dash.
        #expect(lines[2].contains("\u{2013}"))
        // The marker is on the current row and nowhere else.
        #expect(lines[1].contains("*"))
        #expect(!lines[2].contains("*"))
        #expect(!lines[0].contains("*"))
    }

    @Test("A size reads in the unit Finder states a file in, not the one memory is counted in")
    func snapshotSizesUseTheFileStyle() {
        let fileStyle = ByteCountFormatter.string(fromByteCount: 1_500_000_000, countStyle: .file)
        let memoryStyle = ByteCountFormatter.string(
            fromByteCount: 1_500_000_000, countStyle: .memory)
        // The assertion below only means something while the two styles differ
        // for this value, which is the whole reason it was chosen.
        #expect(fileStyle != memoryStyle)

        let rendered = TableRenderer.render(
            [
                SnapshotRow(
                    snapshot(name: "Base"), size: SnapshotSize(bytes: 1_500_000_000, privateBytes: nil))
            ], quiet: false)
        #expect(rendered.contains(fileStyle))
        #expect(!rendered.contains(memoryStyle))
    }

    @Test("A size the app did not answer for reads as unknown, never as nothing at all")
    func anUnansweredSizeReadsAsUnknown() {
        let rendered = TableRenderer.render(
            [SnapshotRow(snapshot(name: "Base"), size: nil)], quiet: false)
        #expect(rendered.contains("Unknown"))
    }

    @Test("A capture date reads in this Mac's own words, not the wire's")
    func snapshotDatesReadAsWords() {
        let rendered = TableRenderer.render(
            [SnapshotRow(snapshot(name: "Base"), size: SnapshotSize(bytes: 0, privateBytes: nil))],
            quiet: false)
        #expect(rendered.contains(taken.formatted(date: .abbreviated, time: .shortened)))
    }

    @Test("--quiet on a snapshot listing prints names alone, one per line")
    func quietSnapshotListingIsNamesOnly() {
        let rows = [
            SnapshotRow(snapshot(name: "Base", isCurrent: true), size: SnapshotSize(bytes: 1, privateBytes: nil)),
            SnapshotRow(snapshot(name: "Before Upgrade"), size: SnapshotSize(bytes: 2, privateBytes: nil)),
        ]
        #expect(TableRenderer.render(rows, quiet: true) == "Base\nBefore Upgrade")
    }

    @Test("A virtual machine with nothing captured prints nothing at all")
    func emptySnapshotListingIsEmpty() {
        #expect(TableRenderer.render([SnapshotRow](), quiet: false).isEmpty)
        #expect(TableRenderer.render([SnapshotRow](), quiet: true).isEmpty)
    }

    @Test("A snapshot's JSON is the wire DTO's own fields plus the size, decodable back")
    func snapshotJSONIsTheWireDTOPlusItsSize() throws {
        let summary = snapshot(name: "Base", isCurrent: true)
        let rendered = try JSONRenderer.render([
            SnapshotRow(summary, size: SnapshotSize(bytes: 8_192, privateBytes: 4_096))
        ])

        // The renderer writes dates ISO 8601, which is the form a script parses
        // and the one the decoder has to be told to read back.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([SnapshotSummary].self, from: Data(rendered.utf8))
        #expect(decoded == [summary])
        let objects = try #require(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [[String: Any]])
        let row = try #require(objects.first)
        for field in [
            "id", "name", "notes", "kind", "createdAt", "isCurrent", "isEphemeralBaseline",
            "sizeBytes", "privateBytes",
        ] {
            #expect(row[field] != nil, "missing \(field)")
        }
        #expect(row["sizeBytes"] as? Int == 8_192)
        #expect(row["privateBytes"] as? Int == 4_096)
    }

    @Test("A size the app did not answer for is absent from the JSON, never a zero")
    func anUnansweredSizeIsAbsentFromJSON() throws {
        let rendered = try JSONRenderer.render(SnapshotRow(snapshot(name: "Base"), size: nil))
        let row = try #require(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        #expect(row["sizeBytes"] == nil)
        #expect(row["privateBytes"] == nil)
        #expect(row["name"] as? String == "Base")
    }

    @Test("Without private bytes the JSON carries the size alone")
    func absentPrivateBytesLeaveTheSizeAlone() throws {
        let rendered = try JSONRenderer.render(
            SnapshotRow(snapshot(name: "Base"), size: SnapshotSize(bytes: 8_192, privateBytes: nil)))
        let row = try #require(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        #expect(row["sizeBytes"] as? Int == 8_192)
        #expect(row["privateBytes"] == nil)
    }

    // MARK: - Named networks

    private var networks: [NetworkSummary] {
        [
            NetworkSummary(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(),
                name: "Lab", kind: .hostOnly, members: [alpha, longName]),
            NetworkSummary(
                id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF") ?? UUID(),
                name: "Spare", kind: .shared, members: []),
        ]
    }

    @Test("A network listing names each network's kind and members, with the identifier last")
    func networkListingCarriesEveryColumn() {
        let lines = TableRenderer.render(networks, quiet: false).components(separatedBy: "\n")

        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("NAME"))
        for heading in ["KIND", "MEMBERS"] {
            #expect(lines[0].contains(heading), "missing \(heading)")
        }
        #expect(lines[0].hasSuffix("ID"))
        // The kind reads as the network.mode value `network create --kind`
        // takes back.
        #expect(lines[1].hasPrefix("Lab"))
        #expect(lines[1].contains("hostOnly"))
        #expect(lines[1].contains("Alpha, \(longName.name)"))
        #expect(lines[1].hasSuffix(networks[0].id.uuidString))
        // A network nobody is on says so, rather than leaving a blank a
        // column reader would skip.
        #expect(lines[2].contains("None"))
        #expect(lines[2].hasSuffix(networks[1].id.uuidString))
        for line in lines { #expect(line == line.trimmingCharacters(in: .whitespaces)) }
    }

    @Test("--quiet on a network listing prints names alone, and an empty library prints nothing")
    func quietNetworkListingIsNamesOnly() {
        #expect(TableRenderer.render(networks, quiet: true) == "Lab\nSpare")
        #expect(TableRenderer.render([NetworkSummary](), quiet: false).isEmpty)
    }

    @Test("A network's JSON is the wire DTO, members and all, decodable back")
    func networkJSONIsTheWireDTO() throws {
        let rendered = try JSONRenderer.render(networks)
        let decoded = try JSONDecoder().decode([NetworkSummary].self, from: Data(rendered.utf8))
        #expect(decoded == networks)
        #expect(rendered.contains("\"kind\" : \"hostOnly\""))
    }

    // MARK: - Groups

    private var groups: [GroupSummary] {
        [
            GroupSummary(
                id: UUID(uuidString: "CCCCCCCC-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(),
                name: "Linux Lab", kind: .smartGroup, members: [alpha, longName]),
            GroupSummary(
                id: UUID(uuidString: "DDDDDDDD-CCCC-DDDD-EEEE-FFFFFFFFFFFF") ?? UUID(),
                name: "Empty", kind: .folder, members: []),
        ]
    }

    @Test("A group listing names each group's kind and members, with the identifier last")
    func groupListingCarriesEveryColumn() {
        let lines = TableRenderer.render(groups, quiet: false).components(separatedBy: "\n")

        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("NAME"))
        for heading in ["KIND", "MEMBERS"] {
            #expect(lines[0].contains(heading), "missing \(heading)")
        }
        #expect(lines[0].hasSuffix("ID"))
        #expect(lines[1].hasPrefix("Linux Lab"))
        #expect(lines[1].contains("smartGroup"))
        #expect(lines[1].contains("Alpha, \(longName.name)"))
        #expect(lines[1].hasSuffix(groups[0].id.uuidString))
        #expect(lines[2].contains("folder"))
        #expect(lines[2].contains("None"))
        #expect(lines[2].hasSuffix(groups[1].id.uuidString))
        for line in lines { #expect(line == line.trimmingCharacters(in: .whitespaces)) }
    }

    @Test("--quiet on a group listing prints the names --smart-group and --folder take back")
    func quietGroupListingIsNamesOnly() {
        #expect(TableRenderer.render(groups, quiet: true) == "Linux Lab\nEmpty")
        #expect(TableRenderer.render([GroupSummary](), quiet: false).isEmpty)
    }

    @Test("A group's JSON is the wire DTO, members and all, decodable back")
    func groupJSONIsTheWireDTO() throws {
        let rendered = try JSONRenderer.render(groups)
        let decoded = try JSONDecoder().decode([GroupSummary].self, from: Data(rendered.utf8))
        #expect(decoded == groups)
        #expect(rendered.contains("\"kind\" : \"smartGroup\""))
        #expect(rendered.contains("\"kind\" : \"folder\""))
        #expect(rendered.contains("\"members\""))
    }

    // MARK: - Configuration

    private let settings = [
        ConfigurationEntry(key: "cpus", value: "4"),
        ConfigurationEntry(key: "network.mode", value: "shared"),
        ConfigurationEntry(key: "clipboard.sharing", value: "true"),
    ]

    private let keyspace = [
        ConfigurationKeyDescriptor(
            name: "cpus", summary: "Virtual CPU cores, within what the guest allows.",
            editableWhileRunning: ["macOS": false, "linux": false]),
        ConfigurationKeyDescriptor(
            name: "ephemeral", summary: "Return the VM to its baseline snapshot.",
            editableWhileRunning: ["macOS": true, "linux": true]),
        ConfigurationKeyDescriptor(
            name: "clipboard.sharing", summary: "Exchange clipboard text with the guest.",
            editableWhileRunning: ["macOS": true, "linux": false]),
        ConfigurationKeyDescriptor(
            name: "dropFiles", summary: "Send dropped files to the guest.",
            editableWhileRunning: ["macOS": true]),
    ]

    @Test("A settings listing names its two columns and keeps the order it was answered in")
    func settingsListingIsKeyAndValue() {
        let lines = TableRenderer.render(settings, quiet: false).components(separatedBy: "\n")

        #expect(lines.count == 4)
        #expect(lines[0].contains("KEY"))
        #expect(lines[0].contains("VALUE"))
        #expect(lines[1].hasPrefix("cpus"))
        #expect(lines[1].hasSuffix("4"))
        #expect(lines[2].contains("network.mode"))
        #expect(lines[3].contains("clipboard.sharing"))
        for line in lines { #expect(line == line.trimmingCharacters(in: .whitespaces)) }
    }

    @Test("--quiet on a settings listing prints the values alone, one per line")
    func quietSettingsListingIsValuesOnly() {
        // Values rather than key=value: a script asking for one setting wants
        // the value, and a whole listing stays line-for-line with `get --keys`.
        #expect(TableRenderer.render(settings, quiet: true) == "4\nshared\ntrue")
    }

    @Test("A virtual machine with no settings to report prints nothing at all")
    func emptySettingsListingIsEmpty() {
        #expect(TableRenderer.render([ConfigurationEntry](), quiet: false).isEmpty)
        #expect(TableRenderer.render([ConfigurationEntry](), quiet: true).isEmpty)
    }

    @Test("A keyspace listing names each key, its summary, and whether a running guest takes it")
    func keyspaceListingCarriesEveryColumn() {
        let lines = TableRenderer.render(keyspace, quiet: false).components(separatedBy: "\n")

        #expect(lines.count == 5)
        for heading in ["KEY", "WHILE RUNNING", "SUMMARY"] {
            #expect(lines[0].contains(heading), "missing \(heading)")
        }
        #expect(lines[1].contains("cpus"))
        #expect(lines[1].contains("No"))
        #expect(lines[1].contains("Virtual CPU cores"))
        #expect(lines[2].contains("Yes"))
        #expect(lines[2].contains("Return the VM"))
        // Taken on some guests the key applies to and not others: the listing
        // names the ones that take it.
        #expect(lines[3].contains("macOS guests"))
        #expect(!lines[3].contains("linux"))
        #expect(lines[3].contains("Exchange clipboard text"))
        // A key that applies to one guest alone answers for that guest alone.
        #expect(lines[4].contains("Yes"))
    }

    @Test("--quiet on a keyspace listing prints the names alone, which get and set take back")
    func quietKeyspaceListingIsNamesOnly() {
        #expect(TableRenderer.render(keyspace, quiet: true) == "cpus\nephemeral\nclipboard.sharing\ndropFiles")
    }

    @Test("An empty keyspace prints nothing at all")
    func emptyKeyspaceListingIsEmpty() {
        #expect(TableRenderer.render([ConfigurationKeyDescriptor](), quiet: false).isEmpty)
        #expect(TableRenderer.render([ConfigurationKeyDescriptor](), quiet: true).isEmpty)
    }

    @Test("Settings JSON is the wire DTOs themselves, decodable back")
    func settingsJSONIsTheWireDTO() throws {
        let entries = try JSONRenderer.render(settings)
        #expect(
            try JSONDecoder().decode([ConfigurationEntry].self, from: Data(entries.utf8))
                == settings)

        let descriptors = try JSONRenderer.render(keyspace)
        #expect(
            try JSONDecoder().decode([ConfigurationKeyDescriptor].self, from: Data(descriptors.utf8))
                == keyspace)
        let objects = try #require(
            try JSONSerialization.jsonObject(with: Data(descriptors.utf8)) as? [[String: Any]])
        for field in ["name", "summary", "editableWhileRunning"] {
            #expect(objects.first?[field] != nil, "missing \(field)")
        }
        // One answer per guest, keyed by the guest's wire name.
        #expect(
            objects.last?["editableWhileRunning"] as? [String: Bool] == ["macOS": true])
    }

    // MARK: - Shares

    private let shares = [
        SharedDirectorySummary(path: "/Users/somebody/Sites", readOnly: false),
        SharedDirectorySummary(path: "/Users/somebody/Reference Material", readOnly: true),
    ]

    @Test("A share listing names its path and whether the guest may write")
    func shareListingIsPathAndAccess() {
        let lines = TableRenderer.render(shares, quiet: false).components(separatedBy: "\n")

        #expect(lines.count == 3)
        #expect(lines[0].contains("PATH"))
        #expect(lines[0].contains("READ-ONLY"))
        #expect(lines[1].hasPrefix("/Users/somebody/Sites"))
        #expect(lines[1].hasSuffix("No"))
        #expect(lines[2].hasSuffix("Yes"))
    }

    @Test("--quiet on a share listing prints exactly what share remove takes back")
    func quietShareListingIsPathsOnly() {
        #expect(
            TableRenderer.render(shares, quiet: true)
                == "/Users/somebody/Sites\n/Users/somebody/Reference Material")
    }

    @Test("A virtual machine sharing nothing prints nothing at all")
    func emptyShareListingIsEmpty() {
        #expect(TableRenderer.render([SharedDirectorySummary](), quiet: false).isEmpty)
        #expect(TableRenderer.render([SharedDirectorySummary](), quiet: true).isEmpty)
    }

    @Test("A cell prints whole, however many UTF-16 units its characters take")
    func aCellIsNotTruncatedByItsUTF16Length() {
        // A path read off the disk is decomposed — "Café" arrives as "e" plus a
        // combining acute — and an emoji is a surrogate pair. Both measure
        // longer in UTF-16 than in the characters the column is sized by, and a
        // cell cut to the shorter measure is a path `share remove` refuses.
        let decomposed = "/Users/somebody/Cafe\u{301}"
        let nonBMP = "/Users/somebody/\u{1F4C1}"
        let lines = TableRenderer.render(
            [
                SharedDirectorySummary(path: decomposed, readOnly: false),
                SharedDirectorySummary(path: nonBMP, readOnly: true),
            ], quiet: false
        ).components(separatedBy: "\n")

        #expect(lines[1].hasPrefix(decomposed))
        #expect(lines[2].hasPrefix(nonBMP))
        // And the column still aligns: each path is widened by characters.
        let starts = [("READ-ONLY", 0), ("No", 1), ("Yes", 2)].map { name, row -> Int in
            guard let range = lines[row].range(of: name) else { return -1 }
            return lines[row].distance(from: lines[row].startIndex, to: range.lowerBound)
        }
        #expect(Set(starts).count == 1)
        #expect(starts[0] > 0)
    }

    @Test("Share JSON is the wire DTO itself, decodable back")
    func shareJSONIsTheWireDTO() throws {
        let rendered = try JSONRenderer.render(shares)

        #expect(
            try JSONDecoder().decode([SharedDirectorySummary].self, from: Data(rendered.utf8))
                == shares)
        let objects = try #require(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [[String: Any]])
        for field in ["path", "readOnly"] {
            #expect(objects.first?[field] != nil, "missing \(field)")
        }
    }

    // MARK: - USB accessories

    private let accessories = [
        USBAccessorySummary(
            registryID: 4_294_967_296, name: "0403:6001 \u{00B7} Vendor-specific",
            vendorID: 0x0403, productID: 0x6001,
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
        USBAccessorySummary(
            registryID: 12, name: "05ac:12a8 \u{00B7} Composite", vendorID: 0x05AC,
            productID: 0x12A8),
    ]

    @Test("A USB listing carries both handles, and quiet prints the one each row is acted on by")
    func usbListingNamesBothHandles() throws {
        let lines = TableRenderer.render(accessories, quiet: false)
            .components(separatedBy: "\n")

        #expect(lines[0].hasPrefix("NAME"))
        #expect(lines[0].contains("ACCESSORY"))
        #expect(lines[0].contains("DEVICE"))
        #expect(lines[1].contains("4294967296"))
        #expect(lines[1].contains("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        // An accessory a guest holds is detached by its attachment, and one no
        // guest holds is attached by its own identifier, so `quiet` prints
        // whichever of them the row's verb takes back.
        #expect(
            TableRenderer.render(accessories, quiet: true)
                == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n12")
    }

    @Test("A guest holding nothing prints nothing at all")
    func emptyUSBListingIsEmpty() {
        #expect(TableRenderer.render([USBAccessorySummary](), quiet: false).isEmpty)
        #expect(TableRenderer.render([USBAccessorySummary](), quiet: true).isEmpty)
    }

    @Test("A listing where no guest holds anything leaves the attachment column out")
    func usbListingWithoutAttachmentsOmitsTheDeviceColumn() throws {
        let free = accessories.filter { $0.deviceID == nil }
        let lines = TableRenderer.render(free, quiet: false).components(separatedBy: "\n")

        // Every row's attachment identifier would be blank, and a column of
        // nothing is not a column.
        #expect(lines[0].hasPrefix("NAME"))
        #expect(lines[0].contains("ACCESSORY"))
        #expect(!lines[0].contains("DEVICE"))
    }

    @Test("USB JSON is the wire DTO itself, decodable back")
    func usbJSONIsTheWireDTO() throws {
        let rendered = try JSONRenderer.render(accessories)

        #expect(
            try JSONDecoder().decode([USBAccessorySummary].self, from: Data(rendered.utf8))
                == accessories)
    }

    // MARK: - Remembered USB accessories

    private let pairings = [
        USBPairingSummary(
            vm: "Alpha", key: "04e8:6300:0100:0373", name: "Samsung Type-C",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        USBPairingSummary(
            vm: "Beta", key: "0403:6001:0100@hub/Port-A@1", name: "Drive (Port-A@1)",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_100)),
    ]

    @Test("A rules listing names the machine, and quiet prints the key forget takes back")
    func usbRulesListingNamesTheMachine() throws {
        let lines = TableRenderer.render(pairings, quiet: false).components(separatedBy: "\n")

        #expect(lines[0].hasPrefix("VM"))
        #expect(lines[0].contains("NAME"))
        #expect(lines[0].contains("KEY"))
        #expect(lines[1].contains("Alpha"))
        #expect(lines[2].contains("Beta"))

        #expect(
            TableRenderer.render(pairings, quiet: true)
                == "04e8:6300:0100:0373\n0403:6001:0100@hub/Port-A@1")
    }

    @Test("A library that remembers nothing prints nothing at all")
    func emptyUSBRulesListingIsEmpty() {
        #expect(TableRenderer.render([USBPairingSummary](), quiet: false).isEmpty)
        #expect(TableRenderer.render([USBPairingSummary](), quiet: true).isEmpty)
    }

    @Test("Rules JSON is the wire DTO itself, decodable back")
    func usbRulesJSONIsTheWireDTO() throws {
        let rendered = try JSONRenderer.render(pairings)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(
            try decoder.decode([USBPairingSummary].self, from: Data(rendered.utf8)) == pairings)
    }

    // MARK: - Addresses

    @Test("Each address case states its own answer, and only one is an address")
    func everyAddressCaseRenders() {
        #expect(TableRenderer.render(GuestIPAddress.observed("10.0.0.2")) == "10.0.0.2")
        #expect(TableRenderer.render(GuestIPAddress.notObserved) == "Not seen")
        #expect(TableRenderer.render(GuestIPAddress.externallyAssigned) == "Assigned by your network")
        #expect(TableRenderer.render(GuestIPAddress.unavailable) == "None")
    }

    @Test("Only an observed address prints; the other three refuse rather than print prose")
    func onlyAnObservedAddressPrints() throws {
        #expect(try KernovaCommand.IP.line(for: .observed("10.0.0.2"), vm: "Alpha") == "10.0.0.2")
        for absent: GuestIPAddress in [.notObserved, .externallyAssigned, .unavailable] {
            do {
                _ = try KernovaCommand.IP.line(for: absent, vm: "Alpha")
                Issue.record("expected a refusal for \(absent)")
            } catch let failure as CLIFailure {
                #expect(failure.code == .refusedByState)
                #expect(failure.message.contains("Alpha"))
            }
        }
    }

    // MARK: - JSON

    @Test("JSON keys are sorted, so two runs diff by content")
    func jsonKeysAreStable() throws {
        let rendered = try JSONRenderer.render([alpha])
        let keys = ["\"id\"", "\"name\"", "\"status\""]
        let positions = keys.compactMap { rendered.range(of: $0)?.lowerBound }
        #expect(positions.count == keys.count)
        #expect(positions == positions.sorted())
    }

    @Test("JSON encodes the wire DTO itself, so the tool and the app share one schema")
    func jsonIsTheWireDTO() throws {
        let rendered = try JSONRenderer.render(info())
        let decoded = try JSONDecoder().decode(VMInfo.self, from: Data(rendered.utf8))
        #expect(decoded == info())
    }

    @Test("A guest address survives the JSON round trip in every case")
    func jsonCarriesEveryAddressCase() throws {
        for address: GuestIPAddress in [
            .observed("10.0.0.2"), .notObserved, .externallyAssigned, .unavailable,
        ] {
            let rendered = try JSONRenderer.render(address)
            #expect(
                try JSONDecoder().decode(GuestIPAddress.self, from: Data(rendered.utf8)) == address)
        }
    }

    @Test("A guest address's JSON names its state, and only an observed one carries an address")
    func addressJSONNamesItsState() throws {
        let expected: [(GuestIPAddress, [String: String])] = [
            (.observed("192.168.64.111"), ["state": "observed", "address": "192.168.64.111"]),
            (.notObserved, ["state": "notObserved"]),
            (.externallyAssigned, ["state": "externallyAssigned"]),
            (.unavailable, ["state": "unavailable"]),
        ]
        for (address, fields) in expected {
            let rendered = try JSONRenderer.render(address)
            let object = try JSONSerialization.jsonObject(with: Data(rendered.utf8))
            #expect(object as? [String: String] == fields)
        }
    }

    @Test("A network name's JSON names its state beside the name or identifier it carries, and reads back")
    func networkNameJSONNamesItsState() throws {
        let id = try #require(UUID(uuidString: "6A1F0B2C-3D4E-4F50-8A6B-7C8D9E0F1A2B"))
        let expected: [(VMNetworkName, [String: String])] = [
            (.named("Lab"), ["state": "named", "name": "Lab"]),
            (.unlisted(id), ["state": "unlisted", "id": id.uuidString]),
            (.unreadable, ["state": "unreadable"]),
        ]
        for (networkName, fields) in expected {
            let rendered = try JSONRenderer.render(networkName)
            let object = try JSONSerialization.jsonObject(with: Data(rendered.utf8))
            #expect(object as? [String: String] == fields)
            #expect(try JSONDecoder().decode(VMNetworkName.self, from: Data(rendered.utf8)) == networkName)
        }
    }

    @Test("info's JSON carries the network name as its state object")
    func infoJSONCarriesTheNetworkNameObject() throws {
        let id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let rendered = try JSONRenderer.render(info(networkMembership: id, networkName: .named("Lab")))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        #expect(object["networkName"] as? [String: String] == ["state": "named", "name": "Lab"])
    }
}
