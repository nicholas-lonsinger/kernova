import Foundation
import Testing

@testable import Kernova

/// The one decode a config file takes, in its two modes: strict, as every
/// load reads, and collecting, as the check reads bytes the strict decode
/// refused.
@Suite("Config file decoding")
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
                    issue: .unrecognized(found: "yes", default: "true")),
                ConfigProblem(
                    path: ConfigValuePath([.key("networkMode")]),
                    issue: .unrecognized(
                        found: Self.unrecognized, default: fresh.networkMode.rawValue)),
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
                    issue: .unrecognized(found: Self.unrecognized, default: nil))
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
                    issue: .unrecognized(
                        found: Self.unrecognized, default: VMNamedNetwork.defaultKind.rawValue))
            ])
        #expect(VMNamedNetwork.defaultKind == VMNamedNetwork.kindsInCreationOrder.first)
    }
}
