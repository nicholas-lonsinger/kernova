import Foundation
import KernovaCommandModel
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
        networkMembership: String = "common", networkName: VMNetworkName? = nil,
        agentStatus: String? = "current", agents: [VMAgentLine] = [],
        hasSavedState: Bool = false, savedStateKernovaVersion: String? = nil
    ) -> VMInfo {
        VMInfo(
            id: alpha.id, name: "Alpha", status: "running", guestOS: "macOS", cpuCount: 4,
            memoryBytes: memoryBytes, networkMode: "nat", networkMembership: networkMembership,
            networkName: networkName, macAddress: "aa:bb:cc:dd:ee:ff",
            ipAddress: ipAddress, agentStatus: agentStatus,
            hasSavedState: hasSavedState, savedStateKernovaVersion: savedStateKernovaVersion, isEphemeral: true,
            snapshotCount: 2, hasSnapshots: false, guestAgent: nil, stateBucket: .stopped,
            bundlePath: "/Users/somebody/VMs/Alpha.kernova", heldByAnotherCopy: false, agents: agents,
            tags: ["Lab", "CI"], createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            lastRunAt: Date(timeIntervalSince1970: 1_765_000_000))
    }

    private let mainDisk = StorageDiskSummary(
        id: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6)), label: "Main Disk", kind: "virtio",
        readOnly: false, path: "/Users/somebody/VMs/Alpha.kernova/Disk.asif", notes: "",
        capacityBytes: 100_000_000_000, usedBytes: 10_100_000_000)
    private let installer = StorageDiskSummary(
        id: UUID(uuid: (6, 5, 4, 3, 2, 1, 0, 9, 8, 7, 6, 5, 4, 3, 2, 1)),
        label: "ubuntu-26.04.1-desktop-arm64", kind: "usbMassStorage", readOnly: true,
        path: "/Users/somebody/Downloads/ubuntu-26.04.1-desktop-arm64.iso", notes: "",
        capacityBytes: 4_150_000_000, usedBytes: 4_150_000_000)
    private let unreadable = StorageDiskSummary(
        id: UUID(uuid: (9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9)), label: "Scratch", kind: "virtio",
        readOnly: false, path: "/Volumes/Gone/Scratch.img", notes: "", capacityBytes: nil, usedBytes: nil)

    private func report(_ info: VMInfo, disks: [StorageDiskSummary]? = nil) -> VMInfoReport {
        VMInfoReport(info, storageDisks: disks ?? [mainDisk])
    }

    // MARK: - Listing

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
            cpuCount: base.cpuCount, memoryBytes: base.memoryBytes,
            networkMode: base.networkMode, networkMembership: base.networkMembership, networkName: nil,
            macAddress: base.macAddress, ipAddress: .notObserved,
            agentStatus: base.agentStatus, hasSavedState: false, savedStateKernovaVersion: nil,
            isEphemeral: base.isEphemeral,
            snapshotCount: base.snapshotCount, hasSnapshots: base.hasSnapshots, guestAgent: base.guestAgent,
            stateBucket: .heldByAnotherCopy,
            bundlePath: base.bundlePath, heldByAnotherCopy: true, agents: [], tags: [],
            createdAt: base.createdAt, lastRunAt: base.lastRunAt)
        let status = try #require(
            TableRenderer.render(report(heldInfo)).components(separatedBy: "\n")
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

    // MARK: - Info

    @Test("info's JSON is the description's own fields beside the ordered disk list, and reads back")
    func infoJSONCarriesTheDiskList() throws {
        let rendered = try JSONRenderer.render(report(info(), disks: [mainDisk, installer, unreadable]))
        let data = Data(rendered.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let disks = try #require(object["storageDisks"] as? [[String: Any]])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(VMInfo.self, from: data) == info())
        #expect(disks.compactMap { $0["label"] as? String } == ["Main Disk", installer.label, "Scratch"])
        #expect(disks[2]["capacityBytes"] == nil)
        #expect(disks[2]["usedBytes"] == nil)
        struct Disks: Decodable { let storageDisks: [StorageDiskSummary] }
        #expect(
            try JSONDecoder().decode(Disks.self, from: data).storageDisks == [mainDisk, installer, unreadable])
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

    @Test("--quiet on a snapshot listing prints names alone, one per line")
    func quietSnapshotListingIsNamesOnly() {
        let rows = [
            SnapshotRow(snapshot(name: "Base", isCurrent: true), size: SnapshotSize(bytes: 1, privateBytes: nil)),
            SnapshotRow(snapshot(name: "Before Upgrade"), size: SnapshotSize(bytes: 2, privateBytes: nil)),
        ]
        #expect(TableRenderer.render(rows, quiet: true) == "Base\nBefore Upgrade")
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

    // MARK: - Named networks

    private var networks: [NetworkSummary] {
        [
            NetworkSummary(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(),
                name: "Lab", kind: .hostOnly, members: [alpha, longName]),
            NetworkSummary(
                id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF") ?? UUID(),
                name: "Spare", kind: .nat, members: []),
        ]
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
        ConfigurationEntry(key: "network.mode", value: "nat"),
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

    @Test("--quiet on a settings listing prints the values alone, one per line")
    func quietSettingsListingIsValuesOnly() {
        // Values rather than key=value: a script asking for one setting wants
        // the value, and a whole listing stays line-for-line with `get --keys`.
        #expect(TableRenderer.render(settings, quiet: true) == "4\nnat\ntrue")
    }

    @Test("--quiet on a keyspace listing prints the names alone, which get and set take back")
    func quietKeyspaceListingIsNamesOnly() {
        #expect(TableRenderer.render(keyspace, quiet: true) == "cpus\nephemeral\nclipboard.sharing\ndropFiles")
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

    @Test("--quiet on a share listing prints exactly what share remove takes back")
    func quietShareListingIsPathsOnly() {
        #expect(
            TableRenderer.render(shares, quiet: true)
                == "/Users/somebody/Sites\n/Users/somebody/Reference Material")
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

    // MARK: - Addresses

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
            #expect(try JSONDecoder().decode(GuestIPAddress.self, from: Data(rendered.utf8)) == address)
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
