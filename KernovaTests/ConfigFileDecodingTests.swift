import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The one decode a config file takes, in its two modes: strict, as every
/// load reads, and collecting, as the check reads bytes the strict decode
/// refused.
@Suite("Config file decoding", .caseScoped)
struct ConfigFileDecodingTests {
    /// A value no field of any config type takes.
    private static let unrecognized = "plan9-mode"

    private func configJSON(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let config = VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi)
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

    @Test("Strict decoding refuses an unrecognized value in a field with a default")
    func strictRefusesADefaultedField() throws {
        let data = try configJSON { $0["networkMode"] = Self.unrecognized }
        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)
        }
    }

    @Test("Collecting decoding records the path, the value found and the default, and repairs to it")
    func collectingRepairsADefaultedField() throws {
        let data = try configJSON {
            $0["networkMode"] = Self.unrecognized
            $0["displayHiDPI"] = "yes"
        }
        let diagnosis = diagnose(data)
        let fresh = VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi)

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

    @Test("An absent defaulted field takes its default in both modes, as no problem")
    func anAbsentDefaultedFieldIsNoProblem() throws {
        let data = try configJSON { $0["networkMode"] = nil }
        let strict = try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)
        #expect(strict.networkMode == VMConfiguration(name: "", guestOS: .linux, bootMode: .efi).networkMode)
        #expect(diagnose(data).problems.isEmpty)
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

    @Test("Problems with defaults before an unrepairable one are all listed, and nothing is repaired")
    func aMixOfProblemsIsNotRepairable() throws {
        let data = try configJSON {
            $0["displayHiDPI"] = "yes"
            $0["createdAt"] = nil
        }
        let diagnosis = diagnose(data)
        #expect(diagnosis.problems.map(\.path?.description) == ["$.displayHiDPI", "$.createdAt"])
        #expect(diagnosis.problems.map(\.isRepairable) == [true, false])
        #expect(diagnosis.repaired == nil)
    }

    @Test("A missing required key is recorded as no value, with no repair")
    func aMissingRequiredKey() throws {
        let data = try configJSON { $0["name"] = nil }
        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)
        }
        let diagnosis = diagnose(data)
        let problem = try #require(diagnosis.problems.first)
        #expect(diagnosis.problems.count == 1)
        #expect(problem == ConfigProblem(path: ConfigValuePath([.key("name")]), issue: .missing))
        #expect(
            problem.reportLine(fileName: "config.json")
                == "$.name: no value. Kernova can\u{2019}t repair this file.")
        #expect(diagnosis.name == nil)
        #expect(diagnosis.repaired == nil)
    }

    @Test("Malformed JSON is recorded as not JSON, with no repair")
    func malformedJSON() throws {
        let data = Data("{ \"name\": ".utf8)
        #expect(throws: DecodingError.self) {
            try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)
        }
        let diagnosis = diagnose(data)
        let problem = try #require(diagnosis.problems.first)
        guard case .notJSON = problem.issue else {
            Issue.record("Expected not-JSON, got \(problem.issue)")
            return
        }
        #expect(problem.path == nil)
        #expect(problem.summary(fileName: "config.json").hasPrefix("config.json isn\u{2019}t valid JSON"))
        #expect(diagnosis.repaired == nil)
    }

    // MARK: - Paths

    @Test("A path renders keys after a dot and array indexes in brackets, nested to any depth")
    func pathsRender() {
        #expect(ConfigValuePath([]).description == "$")
        #expect(ConfigValuePath([.key("networkMode")]).description == "$.networkMode")
        #expect(
            ConfigValuePath([.key("networks"), .index(0), .key("kind")]).description
                == "$.networks[0].kind")
        #expect(
            ConfigValuePath([.key("a"), .index(2), .index(1), .key("b")]).description == "$.a[2][1].b")
    }

    @Test("A problem nested in an array names its index")
    func aNestedProblemNamesItsIndex() throws {
        let disk: [String: Any] = [
            "id": UUID().uuidString, "path": "Disk.asif", "readOnly": false, "label": "Disk",
            "isInternal": true, "kind": "virtio",
        ]
        var bad = disk
        bad["notes"] = 42
        let data = try configJSON { $0["storageDisks"] = [disk, bad] }

        let problems = diagnose(data).problems
        #expect(problems.map(\.path?.description) == ["$.storageDisks[1].notes"])
        #expect(
            problems.first?.reportLine(fileName: "config.json")
                == "$.storageDisks[1].notes: \u{201C}42\u{201D} is not a recognized value. Default: \u{201C}\u{201D}.")
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

    /// A preference whose value is a record, as a config file may hold one.
    private struct Holder: Codable, Equatable {
        struct Inner: Codable, Equatable {
            var mode: VMNetworkMode
        }
        var inner: Inner

        init(inner: Inner) { self.inner = inner }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inner = try c.decode(Inner.self, forKey: .inner, default: Inner(mode: .shared), in: decoder)
        }
    }

    @Test("A record replaced whole by its default keeps the inner cause, not the value found")
    func aReplacedValueKeepsItsCause() throws {
        let data = Data(#"{"inner": {"mode": "plan9-mode"}}"#.utf8)
        let diagnosis = ConfigFileDiagnosis(
            decoding: Holder.self, from: data, decoder: JSONDecoder(), encoder: JSONEncoder())

        let problem = try #require(diagnosis.problems.first)
        #expect(problem.path?.description == "$.inner")
        #expect(problem.issuePath?.description == "$.inner.mode")
        #expect(problem.issue == .unrecognized(found: Self.unrecognized))
        #expect(
            problem.reportLine(fileName: "x.json")
                == "$.inner.mode: \u{201C}\(Self.unrecognized)\u{201D} is not a recognized value. "
                + "Default for $.inner: {\"mode\":\"shared\"}.")
        #expect(
            try JSONDecoder().decode(Holder.self, from: try #require(diagnosis.repaired))
                == Holder(inner: Holder.Inner(mode: .shared)))
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

    private func networkListJSON(kind: String?) -> Data {
        let kindField = kind.map { ", \"kind\": \"\($0)\"" } ?? ""
        return Data(
            """
            {"networks": [{"id": "\(UUID().uuidString)", "name": "Lab"\(kindField)}]}
            """.utf8)
    }

    private func diagnoseNetworks(_ data: Data) -> ConfigFileDiagnosis {
        ConfigFileDiagnosis(
            decoding: [String: [VMNamedNetwork]].self, from: data, decoder: JSONDecoder(),
            encoder: JSONEncoder())
    }

    @Test("A network's missing kind is refused strictly, and repaired to the default kind when collecting")
    func aMissingRequiredKindIsRepairable() throws {
        let data = networkListJSON(kind: nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([String: [VMNamedNetwork]].self, from: data)
        }
        let diagnosis = diagnoseNetworks(data)
        #expect(
            diagnosis.problems == [
                ConfigProblem(
                    path: ConfigValuePath([.key("networks"), .index(0), .key("kind")]), issue: .missing,
                    repair: .useDefault(VMNamedNetwork.defaultKind.rawValue))
            ])
        let repaired = try JSONDecoder().decode(
            [String: [VMNamedNetwork]].self, from: try #require(diagnosis.repaired))
        #expect(repaired["networks"]?.map(\.kind) == [VMNamedNetwork.defaultKind])
    }

    @Test("A network's unrecognized kind is refused strictly, and repaired to the default kind when collecting")
    func anUnrecognizedRequiredKindIsRepairable() throws {
        let data = networkListJSON(kind: Self.unrecognized)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([String: [VMNamedNetwork]].self, from: data)
        }
        #expect(
            diagnoseNetworks(data).problems == [
                ConfigProblem(
                    path: ConfigValuePath([.key("networks"), .index(0), .key("kind")]),
                    issue: .unrecognized(found: Self.unrecognized),
                    repair: .useDefault(VMNamedNetwork.defaultKind.rawValue))
            ])
    }

    // MARK: - The snapshot's captured network

    @Test("A snapshot's captured network reads past what its configuration no longer takes, keeping the address")
    func theCapturedNetworkReadsPastBadValues() throws {
        let data = try configJSON {
            $0["guestOS"] = Self.unrecognized
            $0["networkMode"] = Self.unrecognized
            $0["networkEnabled"] = nil
            $0["macAddress"] = "aa:bb:cc:dd:ee:ff"
        }
        let network = try VMConfiguration.makeJSONDecoder().decodeRepairing(VMCapturedNetwork.self, from: data)
        #expect(network.macAddress == "aa:bb:cc:dd:ee:ff")
        #expect(network.networkMode == .shared)
    }

    @Test("A snapshot's captured network missing networkEnabled had no network device")
    func aMissingCapturedNetworkEnabledReadsOff() throws {
        let data = try configJSON {
            $0["networkEnabled"] = nil
            $0["networkMode"] = nil
            $0["networkMembership"] = nil
            $0["bridgedInterfaceIdentifier"] = nil
            $0["macAddress"] = nil
        }
        let network = try VMConfiguration.makeJSONDecoder().decode(VMCapturedNetwork.self, from: data)
        #expect(
            network
                == VMCapturedNetwork(
                    networkEnabled: false, networkMode: .shared, networkMembership: .common,
                    bridgedInterfaceIdentifier: nil, macAddress: nil))
    }

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
        #expect(network.networkMode == .shared)
    }

    // MARK: - Trashed originals

    @Test("The copy a repair trashes is named for whose file it is, then the file")
    func trashedOriginalNames() {
        let bundle = URL(fileURLWithPath: "/tmp/VMs/Dev.kernova", isDirectory: true)
        let problem = [ConfigProblem(path: nil, issue: .notJSON(detail: "x"))]
        func name(_ location: UnreadableConfigFile.Location, _ owner: UnreadableConfigFile.Owner) -> String {
            UnreadableConfigFile(location: location, owner: owner, problems: problem).trashedOriginalName
        }
        #expect(name(.bundle(bundle, .configuration), .virtualMachine("Dev")) == "Dev \u{2014} config.json")
        #expect(
            name(.bundle(bundle, .snapshotConfiguration(UUID())), .snapshot(vm: "Dev", snapshot: "Before"))
                == "Dev \u{2014} snapshot \u{201C}Before\u{201D} \u{2014} config.json")
        #expect(
            name(.networkList(URL(fileURLWithPath: "/tmp/Networks.json")), .networkList)
                == "Network list \u{2014} Networks.json")
        #expect(
            name(.bundle(bundle, .configuration), .virtualMachine("A/B")) == "A:B \u{2014} config.json")
    }

    @Test("A trashed original's name fits NAME_MAX, its long names shortened on a character boundary")
    func trashedOriginalNamesFitNameMax() throws {
        let bundle = URL(fileURLWithPath: "/tmp/VMs/Dev.kernova", isDirectory: true)
        let problem = [ConfigProblem(path: nil, issue: .notJSON(detail: "x"))]
        let vm = String(repeating: "\u{E9}", count: 60)  // 120 bytes
        let snapshot = String(repeating: "\u{65E5}", count: 43) + "a"  // 130 bytes
        #expect(vm.utf8.count == 120)
        #expect(snapshot.utf8.count == 130)

        let snapshotName = UnreadableConfigFile(
            location: .bundle(bundle, .snapshotConfiguration(UUID())),
            owner: .snapshot(vm: vm, snapshot: snapshot), problems: problem
        ).trashedOriginalName
        #expect(snapshotName.utf8.count <= 255)
        #expect(snapshotName.hasSuffix("\u{2026}\u{201D} \u{2014} config.json"))
        // Every kept character is whole: the result is valid UTF-8 built only
        // from the names' own characters, the ellipsis, and the fixed words.
        let vmPart = try #require(snapshotName.components(separatedBy: " \u{2014} snapshot \u{201C}").first)
        #expect(vmPart.hasSuffix("\u{2026}") || vmPart == vm)
        #expect(vm.hasPrefix(vmPart.replacingOccurrences(of: "\u{2026}", with: "")))
        #expect(snapshotName.contains("\u{65E5}"))

        let vmName = UnreadableConfigFile(
            location: .bundle(bundle, .configuration),
            owner: .virtualMachine(String(repeating: "\u{E9}", count: 200)), problems: problem
        ).trashedOriginalName
        #expect(vmName.utf8.count <= 255)
        #expect(vmName.hasSuffix("\u{E9}\u{2026} \u{2014} config.json"))
    }

    @Test("The network list's kind takes the New Network sheet's default kind")
    func aNamedNetworksKindHasADefault() throws {
        let json = """
            {"networks": [{"id": "\(UUID().uuidString)", "name": "Lab", "kind": "\(Self.unrecognized)"}]}
            """
        let diagnosis = ConfigFileDiagnosis(
            decoding: [String: [VMNamedNetwork]].self, from: Data(json.utf8), decoder: JSONDecoder(),
            encoder: JSONEncoder())
        #expect(
            diagnosis.problems == [
                ConfigProblem(
                    path: ConfigValuePath([.key("networks"), .index(0), .key("kind")]),
                    issue: .unrecognized(found: Self.unrecognized),
                    repair: .useDefault(VMNamedNetwork.defaultKind.rawValue))
            ])
        #expect(VMNamedNetwork.defaultKind == VMNamedNetwork.kindsInCreationOrder.first)
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
        #expect(diagnosis.problems.map(\.repair) == [.removeEntry, .useDefault("null")])
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
        let fresh = VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi)

        #expect(
            diagnosis.problems.map(\.path?.description) == ["$.bridgedInterfaceIdentifier", "$.kernelCommandLine"])
        #expect(diagnosis.problems.map(\.repair) == [.useDefault("null"), .useDefault("null")])
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
        #expect(diagnosis.problems.map(\.repair) == [.useDefault("null")])
        let repaired = try VMConfiguration.makeJSONDecoder().decode(
            VMHostState.self, from: try #require(diagnosis.repaired))
        #expect(repaired.lastFullscreenDisplayID == VMHostState().lastFullscreenDisplayID)
        #expect(repaired.displayPreference == .fullscreen)
    }

    @Test("Sidebar view options that don't decode repair to new options', a filter's bad entry removed alone")
    func sidebarViewOptionsRepair() throws {
        let data = Data(
            #"""
            {"sort": "byColor", "grouping": "state", "showsDetails": 2,
             "filter": {"states": ["running", "levitating"], "ephemeralOnly": "yes", "guestOSes": ["linux"]}}
            """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SidebarViewOptions.self, from: data)
        }
        let diagnosis = ConfigFileDiagnosis(
            decoding: SidebarViewOptions.self, from: data, decoder: JSONDecoder(), encoder: JSONEncoder())
        let fresh = SidebarViewOptions()

        #expect(
            diagnosis.problems.map(\.path?.description) == [
                "$.filter.states[1]", "$.filter.ephemeralOnly", "$.sort", "$.showsDetails",
            ])
        #expect(
            diagnosis.problems.map(\.repair) == [
                .removeEntry, .useDefault(String(fresh.filter.ephemeralOnly)), .useDefault(fresh.sort.rawValue),
                .useDefault(String(fresh.showsDetails)),
            ])
        let repaired = try JSONDecoder().decode(SidebarViewOptions.self, from: try #require(diagnosis.repaired))
        #expect(repaired.sort == fresh.sort)
        #expect(repaired.showsDetails == fresh.showsDetails)
        #expect(repaired.grouping == .state)
        #expect(repaired.filter.states == [.running])
        #expect(repaired.filter.ephemeralOnly == fresh.filter.ephemeralOnly)
        #expect(repaired.filter.guestOSes == [.linux])
    }
}
