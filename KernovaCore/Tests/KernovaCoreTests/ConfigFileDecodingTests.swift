import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The one decode a config file takes, in its two modes: strict, as every
/// load reads, and collecting, as the check reads bytes the strict decode
/// refused.
@Suite("Config file decoding", .caseScoped)
struct ConfigFileDecodingTests {
    /// A value no field of any config type takes.
    private static let unrecognized = "plan9-mode"

    private func configJSON(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let config = VMConfiguration(
            name: "Dev", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let data = try VMConfiguration.makeJSONEncoder().encode(config)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func diagnose(_ data: Data) -> ConfigFileDiagnosis {
        ConfigFileDiagnosis(
            decoding: VMConfiguration.self, from: data, decoder: VMConfiguration.makeJSONDecoder(),
            encoder: VMConfiguration.makeJSONEncoder())
    }

    // MARK: - A field with a default

    @Test("Collecting decoding records the path, the value found and the default, and repairs to it")
    func collectingRepairsADefaultedField() throws {
        let data = try configJSON {
            $0["networkMode"] = Self.unrecognized
            $0["displayHiDPI"] = "yes"
        }
        let diagnosis = diagnose(data)
        let fresh = VMConfiguration(
            name: "Dev", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)

        #expect(
            diagnosis.problems == [
                ConfigProblem(
                    path: ConfigValuePath([.key("displayHiDPI")]),
                    issue: .unrecognized(found: "yes"), repair: .useDefault("true")),
                ConfigProblem(
                    path: ConfigValuePath([.key("networkMode")]),
                    issue: .unrecognized(found: Self.unrecognized), repair: .useDefault(fresh.networkMode.rawValue)),
            ])
        #expect(diagnosis.name == "Dev")
        let repaired = try VMConfiguration.makeJSONDecoder().decode(
            VMConfiguration.self, from: try #require(diagnosis.repaired))
        #expect(repaired.networkMode == fresh.networkMode)
        #expect(repaired.displayHiDPI == fresh.displayHiDPI)
        #expect(repaired.name == "Dev")
    }

    // MARK: - Fields with no default, and structure

    @Test("A bad value in a field with no default is recorded with no repair")
    func anUndefaultedFieldHasNoRepair() throws {
        let data = try configJSON {
            $0["guestOS"] = Self.unrecognized
        }
        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)
        }
        let diagnosis = diagnose(data)
        #expect(
            diagnosis.problems == [
                ConfigProblem(
                    path: ConfigValuePath([.key("guestOS")]),
                    issue: .unrecognized(found: Self.unrecognized))
            ])
        #expect(diagnosis.repaired == nil)
    }

    // MARK: - A list of entries

    @Test("A bad entry in a defaulted list is its own problem, removed, with its cause; the rest are kept")
    func aBadEntryIsRemovedAlone() throws {
        let pairings = (0..<3).map {
            USBAccessoryPairing(
                key: "key-\($0)", form: .serialNumber, displayName: "Device \($0)", receptacleLabel: nil,
                pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let encoder = VMConfiguration.makeJSONEncoder()
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: encoder.encode(USBAccessoryPairingSet(pairings: pairings))) as? [String: Any])
        var entries = try #require(object["pairings"] as? [[String: Any]])
        entries[1]["form"] = Self.unrecognized
        object["pairings"] = entries
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(USBAccessoryPairingSet.self, from: data)
        }
        let diagnosis = ConfigFileDiagnosis(
            decoding: USBAccessoryPairingSet.self, from: data, decoder: VMConfiguration.makeJSONDecoder(),
            encoder: encoder)

        let problem = try #require(diagnosis.problems.first)
        #expect(diagnosis.problems.count == 1)
        #expect(problem.path?.description == "$.pairings[1]")
        #expect(problem.issuePath?.description == "$.pairings[1].form")
        #expect(problem.repair == .removeEntry)
        #expect(
            problem.reportLine(fileName: "usb-accessories.json")
                == "$.pairings[1].form: \u{201C}\(Self.unrecognized)\u{201D} is not a recognized value. "
                + "Use Defaults removes this entry.")
        let repaired = try VMConfiguration.makeJSONDecoder().decode(
            USBAccessoryPairingSet.self, from: try #require(diagnosis.repaired))
        #expect(repaired.pairings == [pairings[0], pairings[2]])
    }

    // MARK: - Facts

    private func snapshotRecordJSON(kind: String?) -> Data {
        let kindField = kind.map { ", \"kind\": \"\($0)\"" } ?? ""
        return Data(
            """
            {"id": "\(UUID().uuidString)", "name": "Before", "createdAt": "2026-01-01T00:00:00Z", "notes": ""\(kindField)}
            """.utf8)
    }

    @Test("A fact with no value reads as what its absence states, in both modes, as no problem")
    func anAbsentFactIsItsStatedValue() throws {
        let data = snapshotRecordJSON(kind: nil)
        let strict = try VMConfiguration.makeJSONDecoder().decode(VMSnapshotRecord.self, from: data)
        #expect(strict.kind == .warm)
        let diagnosis = ConfigFileDiagnosis(
            decoding: VMSnapshotRecord.self, from: data, decoder: VMConfiguration.makeJSONDecoder(),
            encoder: VMConfiguration.makeJSONEncoder())
        #expect(diagnosis.problems.isEmpty)
    }

    @Test("A fact holding an unrecognized value is refused strictly, and recorded with no repair")
    func anUnrecognizedFactHasNoRepair() throws {
        let data = snapshotRecordJSON(kind: Self.unrecognized)
        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(VMSnapshotRecord.self, from: data)
        }
        let diagnosis = ConfigFileDiagnosis(
            decoding: VMSnapshotRecord.self, from: data, decoder: VMConfiguration.makeJSONDecoder(),
            encoder: VMConfiguration.makeJSONEncoder())
        #expect(
            diagnosis.problems == [
                ConfigProblem(path: ConfigValuePath([.key("kind")]), issue: .unrecognized(found: Self.unrecognized))
            ])
        #expect(diagnosis.repaired == nil)
        #expect(
            diagnosis.problems.first?.reportLine(fileName: "manifest.json")
                == "$.kind: \u{201C}\(Self.unrecognized)\u{201D} is not a recognized value. "
                + "Kernova can\u{2019}t repair this file.")
    }

    // MARK: - Required, repairable

    @Test("An unrecognized device shape is refused strictly, and recorded with no repair")
    func anUnrecognizedDeviceShapeHasNoRepair() throws {
        let data = try configJSON { $0["deviceShape"] = Self.unrecognized }
        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)
        }
        let diagnosis = diagnose(data)
        #expect(
            diagnosis.problems == [
                ConfigProblem(
                    path: ConfigValuePath([.key("deviceShape")]), issue: .unrecognized(found: Self.unrecognized))
            ])
        #expect(diagnosis.repaired == nil)
    }

    // MARK: - The snapshot's captured network

    @Test("A snapshot's captured network lists an unrecognized value as a problem no default repairs")
    func anUnrecognizedCapturedNetworkValueIsUnrepairable() throws {
        let data = try configJSON {
            $0["networkEnabled"] = Self.unrecognized
            $0["networkMode"] = Self.unrecognized
        }
        let diagnosis = ConfigFileDiagnosis(
            decoding: VMCapturedNetwork.self, from: data, decoder: VMConfiguration.makeJSONDecoder(),
            encoder: VMConfiguration.makeJSONEncoder())
        #expect(
            diagnosis.problems.map(\.path) == [
                ConfigValuePath([.key("networkEnabled")]), ConfigValuePath([.key("networkMode")]),
            ])
        #expect(diagnosis.problems.allSatisfy { $0.repair == nil })
        #expect(diagnosis.repaired == nil)
        // The lenient read still answers: each value as its absence reads.
        let network = try VMConfiguration.makeJSONDecoder().decodeRepairing(VMCapturedNetwork.self, from: data)
        #expect(network.networkEnabled == false)
        #expect(network.networkMode == .nat)
    }

    // MARK: - Organization fields

    @Test("A VM's tag that doesn't decode is removed alone, and a last run that doesn't repairs to none recorded")
    func hostStateTagsAndLastRunRepair() throws {
        let kept = UUID()
        let data = Data(#"{"tags": ["\#(kept.uuidString)", 7], "lastRunAt": "yesterday"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(VMHostState.self, from: data)
        }
        let diagnosis = ConfigFileDiagnosis(
            decoding: VMHostState.self, from: data, decoder: VMConfiguration.makeJSONDecoder(),
            encoder: VMConfiguration.makeJSONEncoder())

        #expect(diagnosis.problems.map(\.path?.description) == ["$.tags[1]", "$.lastRunAt"])
        #expect(diagnosis.problems.map(\.repair) == [.removeEntry, .useDefault(nil)])
        let repaired = try VMConfiguration.makeJSONDecoder().decode(
            VMHostState.self, from: try #require(diagnosis.repaired))
        #expect(repaired.tags == [kept])
        #expect(repaired.lastRunAt == nil)
    }

    @Test("A folder, a section or a tag in the organization file that doesn't decode is removed alone")
    func organizationEntriesRepairOneByOne() throws {
        let folder = UUID()
        let tag = UUID()
        let data = Data(
            #"""
            {"smartGroups": [],
             "folders": [{"id": "\#(folder.uuidString)", "name": "Lab", "members": []}, {"name": 3}],
             "sectionOrder": ["virtualMachines", 4],
             "tags": [{"id": "\#(tag.uuidString)", "name": "Work", "color": "red"},
                      {"id": "\#(UUID().uuidString)", "name": "Home", "color": "plaid"}]}
            """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VMOrganizationDirectory.File.self, from: data)
        }
        let diagnosis = ConfigFileDiagnosis(
            decoding: VMOrganizationDirectory.File.self, from: data, decoder: JSONDecoder(), encoder: JSONEncoder())

        #expect(diagnosis.problems.map(\.path?.description) == ["$.folders[1]", "$.sectionOrder[1]", "$.tags[1]"])
        #expect(diagnosis.problems.allSatisfy { $0.repair == .removeEntry })
        let repaired = try JSONDecoder().decode(
            VMOrganizationDirectory.File.self, from: try #require(diagnosis.repaired))
        #expect(repaired.folders.map(\.id) == [folder])
        #expect(repaired.tags.map(\.id) == [tag])
        #expect(repaired.sections.map(\.id) == [.library, .folder(folder)])
    }

    // MARK: - Preferences repaired to a new instance's value

    @Test("A VM's bridged interface and kernel command line that don't decode repair to a new VM's")
    func configurationOptionalPreferencesRepair() throws {
        let data = try configJSON {
            $0["bridgedInterfaceIdentifier"] = 5
            $0["kernelCommandLine"] = ["console=hvc0"]
        }
        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)
        }
        let diagnosis = diagnose(data)
        let fresh = VMConfiguration(
            name: "Dev", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)

        #expect(
            diagnosis.problems.map(\.path?.description) == ["$.bridgedInterfaceIdentifier", "$.kernelCommandLine"])
        #expect(diagnosis.problems.map(\.repair) == [.useDefault(nil), .useDefault(nil)])
        let repaired = try VMConfiguration.makeJSONDecoder().decode(
            VMConfiguration.self, from: try #require(diagnosis.repaired))
        #expect(repaired.bridgedInterfaceIdentifier == fresh.bridgedInterfaceIdentifier)
        #expect(repaired.kernelCommandLine == fresh.kernelCommandLine)
    }

    @Test("A VM's fullscreen display that doesn't decode repairs to a new VM's")
    func hostStateFullscreenDisplayRepairs() throws {
        let data = Data(#"{"lastFullscreenDisplayID": "main", "displayPreference": "fullscreen"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(VMHostState.self, from: data)
        }
        let diagnosis = ConfigFileDiagnosis(
            decoding: VMHostState.self, from: data, decoder: VMConfiguration.makeJSONDecoder(),
            encoder: VMConfiguration.makeJSONEncoder())

        #expect(diagnosis.problems.map(\.path?.description) == ["$.lastFullscreenDisplayID"])
        #expect(diagnosis.problems.map(\.repair) == [.useDefault(nil)])
        let repaired = try VMConfiguration.makeJSONDecoder().decode(
            VMHostState.self, from: try #require(diagnosis.repaired))
        #expect(repaired.lastFullscreenDisplayID == VMHostState().lastFullscreenDisplayID)
        #expect(repaired.displayPreference == .fullscreen)
    }

    // MARK: - Smart groups

    @Test("A smart group that doesn't decode is removed alone; a file with none lists none")
    func aBadSmartGroupIsRemovedAlone() throws {
        let group = UUID()
        let data = Data(
            #"""
            {"smartGroups": [{"id": "\#(group.uuidString)", "name": "All", "filter": {}}, {"name": "Unnamed"}]}
            """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VMOrganizationDirectory.File.self, from: data)
        }
        let diagnosis = ConfigFileDiagnosis(
            decoding: VMOrganizationDirectory.File.self, from: data, decoder: JSONDecoder(), encoder: JSONEncoder())

        #expect(diagnosis.problems.map(\.path?.description) == ["$.smartGroups[1]"])
        let repaired = try JSONDecoder().decode(
            VMOrganizationDirectory.File.self, from: try #require(diagnosis.repaired))
        #expect(repaired.smartGroups.map(\.id) == [group])
        #expect(try JSONDecoder().decode(VMOrganizationDirectory.File.self, from: Data("{}".utf8)) == .init())
    }
}
