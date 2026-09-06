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
        #expect(TableRenderer.render([], quiet: false).isEmpty)
        #expect(TableRenderer.render([], quiet: true).isEmpty)
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
