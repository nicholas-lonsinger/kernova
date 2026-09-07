import Foundation
import KernovaKit
import Testing

@testable import KernovaCLICore

/// What the tool prints, for a person and for a script.
@Suite("CLI rendering", .admissionGated)
struct CLIRenderingTests {
    private let alpha = VMSummary(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
        name: "Alpha", status: "running", ipAddress: .reserved("192.168.64.4"))
    private let longName = VMSummary(
        id: UUID(uuidString: "66666666-7777-8888-9999-000000000000") ?? UUID(),
        name: "A Much Longer Name", status: "initialBoot", ipAddress: .pending)

    private func info(ipAddress: GuestIPAddress = .reserved("192.168.64.4")) -> VMInfo {
        VMInfo(
            id: alpha.id, name: "Alpha", status: "running", guestOS: "macOS", cpuCount: 4,
            memoryBytes: 8 << 30, diskSizeInGB: 64, networkMode: "shared",
            macAddress: "aa:bb:cc:dd:ee:ff", ipAddress: ipAddress, agentStatus: "current",
            hasSavedState: false, isEphemeral: true, snapshotCount: 2,
            bundlePath: "/Users/somebody/VMs/Alpha.kernova")
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
        #expect(lines[2].contains("Pending"))
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
            SnapshotRow(snapshot(name: "Base", isCurrent: true), onDiskBytes: 1_500_000_000),
            SnapshotRow(snapshot(name: "Before Upgrade", kind: "cold"), onDiskBytes: 0),
        ]
        let lines = TableRenderer.render(rows, quiet: false).components(separatedBy: "\n")

        #expect(lines.count == 3)
        for heading in ["NAME", "CURRENT", "KIND", "TAKEN", "SIZE", "ID"] {
            #expect(lines[0].contains(heading), "missing \(heading)")
        }
        #expect(lines[1].contains("Base"))
        #expect(lines[1].contains("warm"))
        #expect(lines[2].contains("cold"))
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
            [SnapshotRow(snapshot(name: "Base"), onDiskBytes: 1_500_000_000)], quiet: false)
        #expect(rendered.contains(fileStyle))
        #expect(!rendered.contains(memoryStyle))
    }

    @Test("A size the app did not answer for reads as unknown, never as nothing at all")
    func anUnansweredSizeReadsAsUnknown() {
        let rendered = TableRenderer.render(
            [SnapshotRow(snapshot(name: "Base"), onDiskBytes: nil)], quiet: false)
        #expect(rendered.contains("Unknown"))
    }

    @Test("A capture date reads in this Mac's own words, not the wire's")
    func snapshotDatesReadAsWords() {
        let rendered = TableRenderer.render(
            [SnapshotRow(snapshot(name: "Base"), onDiskBytes: 0)], quiet: false)
        #expect(rendered.contains(taken.formatted(date: .abbreviated, time: .shortened)))
    }

    @Test("--quiet on a snapshot listing prints names alone, one per line")
    func quietSnapshotListingIsNamesOnly() {
        let rows = [
            SnapshotRow(snapshot(name: "Base", isCurrent: true), onDiskBytes: 1),
            SnapshotRow(snapshot(name: "Before Upgrade"), onDiskBytes: 2),
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
        let rendered = try JSONRenderer.render([SnapshotRow(summary, onDiskBytes: 4_096)])

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
            "onDiskBytes",
        ] {
            #expect(row[field] != nil, "missing \(field)")
        }
        #expect(row["onDiskBytes"] as? Int == 4_096)
    }

    @Test("A size the app did not answer for is absent from the JSON, never a zero")
    func anUnansweredSizeIsAbsentFromJSON() throws {
        let rendered = try JSONRenderer.render(SnapshotRow(snapshot(name: "Base"), onDiskBytes: nil))
        let row = try #require(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        #expect(row["onDiskBytes"] == nil)
        #expect(row["name"] as? String == "Base")
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
            editableWhileRunning: false),
        ConfigurationKeyDescriptor(
            name: "clipboard.sharing", summary: "Exchange clipboard text with the guest.",
            editableWhileRunning: true),
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

        #expect(lines.count == 3)
        for heading in ["KEY", "WHILE RUNNING", "SUMMARY"] {
            #expect(lines[0].contains(heading), "missing \(heading)")
        }
        #expect(lines[1].contains("cpus"))
        #expect(lines[1].contains("No"))
        #expect(lines[1].contains("Virtual CPU cores"))
        #expect(lines[2].contains("Yes"))
        #expect(lines[2].contains("Exchange clipboard text"))
    }

    @Test("--quiet on a keyspace listing prints the names alone, which get and set take back")
    func quietKeyspaceListingIsNamesOnly() {
        #expect(TableRenderer.render(keyspace, quiet: true) == "cpus\nclipboard.sharing")
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
    }

    // MARK: - Addresses

    @Test("Each address case states its own answer, and only one is an address")
    func everyAddressCaseRenders() {
        #expect(TableRenderer.render(GuestIPAddress.reserved("10.0.0.2")) == "10.0.0.2")
        #expect(TableRenderer.render(GuestIPAddress.pending) == "Pending")
        #expect(TableRenderer.render(GuestIPAddress.externallyAssigned) == "Assigned by your network")
        #expect(TableRenderer.render(GuestIPAddress.unavailable) == "None")
    }

    @Test("Only a reserved address prints; the other three refuse rather than print prose")
    func onlyAReservedAddressPrints() throws {
        #expect(try KernovaCommand.IP.line(for: .reserved("10.0.0.2"), vm: "Alpha") == "10.0.0.2")
        for absent: GuestIPAddress in [.pending, .externallyAssigned, .unavailable] {
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
            .reserved("10.0.0.2"), .pending, .externallyAssigned, .unavailable,
        ] {
            let rendered = try JSONRenderer.render(address)
            #expect(
                try JSONDecoder().decode(GuestIPAddress.self, from: Data(rendered.utf8)) == address)
        }
    }
}
