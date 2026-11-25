import Cocoa
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaUI

/// The scripting dictionary the app ships, against the code it names.
///
/// The dictionary is data the system reads, so nothing in the app fails to
/// compile when a term stops matching what it points at. These are the checks
/// that would otherwise only fire as a script's "can't get" at runtime.
@Suite("Kernova scripting definition", .caseScoped)
struct KernovaScriptingDefinitionTests {
    /// The dictionary as the built app carries it, with the Standard Suite it
    /// includes already substituted in.
    private func loadDictionary() throws -> XMLDocument {
        let declared = try #require(
            Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String)
        let url = try #require(
            Bundle.main.url(
                forResource: (declared as NSString).deletingPathExtension, withExtension: "sdef"))
        return try XMLDocument(contentsOf: url, options: [.documentXInclude])
    }

    /// Kernova's own suite, which is everything this app adds to the Standard
    /// Suite it includes.
    private func loadSuite() throws -> XMLElement {
        let nodes = try loadDictionary().nodes(forXPath: "/dictionary/suite[@name='Kernova Suite']")
        return try #require(nodes.first as? XMLElement)
    }

    /// The values of `attribute` on every node `xpath` selects.
    private func values(_ xpath: String, _ attribute: String, in element: XMLElement) throws
        -> [String]
    {
        try element.nodes(forXPath: xpath).compactMap {
            ($0 as? XMLElement)?.attribute(forName: attribute)?.stringValue
        }
    }

    // MARK: - What the dictionary points at

    @Test("Every command the dictionary names is handled by a script command class")
    func everyCommandHasItsHandler() throws {
        let suite = try loadSuite()
        // What each verb addresses by its direct parameter, one or a list of
        // them, or for `import` a file, named by itself or by its path.
        let addressed = [
            "start": "virtual machine", "stop": "virtual machine", "restart": "virtual machine",
            "pause": "virtual machine", "resume": "virtual machine", "suspend": "virtual machine",
            "reveal": "virtual machine", "revert to": "snapshot", "cancel guest setup": "virtual machine",
            "cancel copy": "virtual machine", "change": "setting", "attach": "USB accessory",
            "detach": "USB accessory",
        ]
        #expect(Set(try values("command", "name", in: suite)) == Set(addressed.keys).union(["import"]))

        for command in try suite.nodes(forXPath: "command").compactMap({ $0 as? XMLElement }) {
            let name = try #require(command.attribute(forName: "name")?.stringValue)
            let handler = try #require(try values("cocoa", "class", in: command).first)
            let handlerClass: AnyClass = try #require(NSClassFromString(handler))
            #expect(handlerClass is VMScriptCommand.Type, "\(handler) is not a Kernova verb")
            guard let type = addressed[name] else {
                #expect(try values("direct-parameter/type", "type", in: command) == ["file", "text"])
                continue
            }
            // A group action's verb takes a group too, and answers what it
            // acted on; every other verb on VMs answers nothing.
            let actsOnGroups = handlerClass is any VMGroupActionCommand.Type
            let groups = actsOnGroups ? ["smart group", "folder"] : []
            #expect(try values("direct-parameter/type", "type", in: command) == [type, type] + groups)
            #expect(try values("direct-parameter/type", "list", in: command) == ["yes"])
            if type == "virtual machine" {
                #expect(command.elements(forName: "result").count == (actsOnGroups ? 1 : 0), "\(name)")
                let answers = try values("result/type", "type", in: command)
                #expect(answers == (actsOnGroups ? ["specifier", "specifier"] : []), "\(name)")
                #expect(try values("result/type", "list", in: command) == (actsOnGroups ? ["yes"] : []), "\(name)")
            }
        }
    }

    @Test("Each class reads each field of its record by the key its accounting names, and no other key")
    @MainActor
    func everyFieldHasItsTerm() throws {
        let suite = try loadSuite()
        let classes: [(name: String, object: NSObject.Type, keys: [String])] = [
            (
                "virtual machine", VMScriptObject.self,
                VMInfo.Field.allCases.compactMap(VMScriptObject.key(carrying:))
                    + [
                        VMScriptObject.storageDisksKey, VMScriptObject.snapshotsKey, VMScriptObject.settingsKey,
                        VMScriptObject.sharedDirectoriesKey, VMScriptObject.usbAccessoriesKey,
                        VMScriptObject.rememberedUSBAccessoriesKey,
                    ]
            ),
            (
                "shared directory", VMSharedDirectoryScriptObject.self,
                SharedDirectorySummary.Field.allCases.map(VMSharedDirectoryScriptObject.key(carrying:))
                    // The folder's own name, which the path ends in.
                    + [#keyPath(VMSharedDirectoryScriptObject.name)]
            ),
            (
                "USB accessory", VMUSBAccessoryScriptObject.self,
                USBAccessorySummary.Field.allCases.compactMap(VMUSBAccessoryScriptObject.key(carrying:))
            ),
            (
                "remembered USB accessory", VMRememberedUSBAccessoryScriptObject.self,
                USBPairingSummary.Field.allCases.compactMap(VMRememberedUSBAccessoryScriptObject.key(carrying:))
            ),
            (
                // The keyspace's entry and its key's descriptor, but for
                // whether a running VM takes the key, which a refused write
                // names.
                "setting", VMSettingScriptObject.self,
                [
                    #keyPath(VMSettingScriptObject.name), #keyPath(VMSettingScriptObject.value),
                    #keyPath(VMSettingScriptObject.summary),
                ]
            ),
            (
                "snapshot", VMSnapshotScriptObject.self,
                SnapshotSummary.Field.allCases.map(VMSnapshotScriptObject.key(carrying:))
                    // Measured apart from the listing.
                    + [#keyPath(VMSnapshotScriptObject.size), #keyPath(VMSnapshotScriptObject.privateSize)]
            ),
            (
                "guest agent", VMGuestAgentScriptObject.self,
                VMAgentLine.Field.allCases.map(VMGuestAgentScriptObject.key(carrying:))
            ),
            (
                "storage disk", VMStorageDiskScriptObject.self,
                StorageDiskSummary.Field.allCases.map(VMStorageDiskScriptObject.key(carrying:))
            ),
            (
                "network", VMNetworkScriptObject.self,
                NetworkSummary.Field.allCases.map(VMNetworkScriptObject.key(carrying:))
            ),
            (
                "smart group", VMSmartGroupScriptObject.self,
                GroupSummary.Field.allCases.compactMap(VMGroupScriptObject.key(carrying:))
            ),
            (
                "folder", VMFolderScriptObject.self,
                GroupSummary.Field.allCases.compactMap(VMGroupScriptObject.key(carrying:))
            ),
        ]

        for (name, object, accounted) in classes {
            let keys = try values("class[@name='\(name)']/*[self::property or self::element]/cocoa", "key", in: suite)
            #expect(Set(keys) == Set(accounted), "\(name)")
            for key in keys {
                #expect(object.instancesRespond(to: NSSelectorFromString(key)), "\(object) answers to no \(key)")
            }
        }
    }

    @Test("A virtual machine's name and a setting's value are writable, through a setter; the rest read only")
    func theWritablePropertiesHaveSetters() throws {
        let classes: [(name: String, object: NSObject.Type, writable: Set<String>)] = [
            ("virtual machine", VMScriptObject.self, ["name"]),
            ("setting", VMSettingScriptObject.self, ["value"]),
        ]

        for (className, object, writable) in classes {
            let nodes = try loadSuite().nodes(forXPath: "class[@name='\(className)']")
            let element = try #require(nodes.first as? XMLElement)
            let properties = try element.nodes(forXPath: "property").compactMap { $0 as? XMLElement }
            for property in properties {
                let name = try #require(property.attribute(forName: "name")?.stringValue)
                let access = property.attribute(forName: "access")?.stringValue
                if writable.contains(name) {
                    #expect(access == nil, "\(className) \(name) is read only")
                    let key = try #require(try values("cocoa", "key", in: property).first)
                    let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
                    #expect(
                        object.instancesRespond(to: NSSelectorFromString(setter)), "\(object) answers to no \(setter)")
                } else {
                    #expect(access == "r", "\(className) \(name) is writable")
                }
            }
            let names = Set(properties.compactMap { $0.attribute(forName: "name")?.stringValue })
            #expect(writable.isSubset(of: names), "\(className)")
        }
    }

    @Test("A network's name is writable and its kind and identifier read only")
    func aNetworkIsRenamedByItsName() throws {
        let classes = try loadSuite().nodes(forXPath: "class[@name='network']")
        let network = try #require(classes.first as? XMLElement)

        // A rename is a `set name`; the kind is fixed when a network is made.
        #expect(try values("property[@name='name']", "access", in: network).isEmpty)
        #expect(try values("property[@name='kind']", "access", in: network) == ["r"])
        #expect(try values("property[@name='id']", "access", in: network) == ["r"])
        #expect(VMNetworkScriptObject.instancesRespond(to: NSSelectorFromString("setName:")))
    }

    @Test("A storage disk is named storage disks in the plural, and none of its properties is writable")
    func storageDisksAreReadOnly() throws {
        let classes = try loadSuite().nodes(forXPath: "class[@name='storage disk']")
        let disk = try #require(classes.first as? XMLElement)
        let properties = try disk.nodes(forXPath: "property").compactMap { $0 as? XMLElement }

        #expect(disk.attribute(forName: "plural")?.stringValue == "storage disks")
        for property in properties {
            let name = try #require(property.attribute(forName: "name")?.stringValue)
            #expect(property.attribute(forName: "access")?.stringValue == "r", "\(name) is writable")
        }
        // `id` is what Cocoa resolves `storage disk id "…"` against.
        #expect(try values("property[@name='id']", "code", in: disk) == ["ID  "])
    }

    @Test("A term the dictionary gives two classes carries one code in both")
    func sharedTermsShareACode() throws {
        let suite = try loadSuite()
        var codes: [String: Set<String>] = [:]
        for case let property as XMLElement in try suite.nodes(forXPath: "class/property") {
            guard let name = property.attribute(forName: "name")?.stringValue,
                let code = property.attribute(forName: "code")?.stringValue
            else { continue }
            codes[name, default: []].insert(code)
        }

        for (name, used) in codes {
            #expect(used.count == 1, "\(name) carries the codes \(used.sorted())")
        }
        #expect(codes["kind"] == ["KvKd"])
    }

    @Test("The application's networks element reads, makes and deletes through the delegate")
    func theNetworksElementIsTheDelegateKey() throws {
        let extensions = try loadSuite().nodes(
            forXPath: "class-extension[@extends='application']/element[@type='network']")
        let element = try #require(extensions.first as? XMLElement)

        let key = try #require(try values("cocoa", "key", in: element).first)

        #expect(key == VMScriptingRoot.networksKey)
        #expect(VMScriptingRoot.scriptingKeys.contains(key))
        // The spellings Cocoa's KVC looks for, which nothing else checks.
        for selector in [
            key, "insertInNetworks:", "insertInNetworks:atIndex:", "removeFromNetworksAtIndex:",
        ] {
            #expect(
                VMScriptingRoot.instancesRespond(to: NSSelectorFromString(selector)),
                "The scripting root answers to no \(selector)")
        }
    }

    @Test("Every class that holds elements resolves the names a script gives them, the application by its delegate")
    func everyContainerResolvesItsElementsNames() throws {
        let containers = try values("class[element]/cocoa", "class", in: loadSuite())

        #expect(!containers.isEmpty)
        for name in containers {
            let container: AnyClass = try #require(NSClassFromString(name), "\(name)")
            #expect(container is VMScriptContainer.Type, "\(name) is not a VMScriptContainer")
        }
        #expect(KernovaApplication.isSubclass(of: VMScriptingApplication.self))
    }

    // MARK: - Enumerations

    /// The `name`/`code` pairs of one enumeration's enumerators.
    private func enumerators(_ enumeration: String) throws -> [String: FourCharCode] {
        let suite = try loadSuite()
        let nodes = try suite.nodes(forXPath: "enumeration[@name='\(enumeration)']/enumerator")
        var terms: [String: FourCharCode] = [:]
        for case let node as XMLElement in nodes {
            guard let name = node.attribute(forName: "name")?.stringValue,
                let code = node.attribute(forName: "code")?.stringValue
            else { continue }
            terms[name] = FourCharCode(scriptingCode: code)
        }
        return terms
    }

    @Test("Every state a VM can report has a term a script can compare against")
    func everyStateHasAnEnumerator() throws {
        let declared = try enumerators("VM state")

        let terms: [VMScriptState: String] = [
            .stopped: "stopped", .starting: "starting", .running: "running", .paused: "paused",
            .suspended: "suspended", .saving: "saving", .snapshotting: "snapshotting", .cloning: "cloning",
            .restoring: "restoring", .installing: "installing", .forceStopping: "force stopping",
            .initialBoot: "initial boot", .failed: "failed", .preparing: "preparing",
        ]

        // `VMScriptState` covers every `VMReportedStatus` by an exhaustive
        // switch, so a new status cannot compile without landing here.
        #expect(declared.count == VMScriptState.allCases.count)
        for state in VMScriptState.allCases {
            let term = try #require(terms[state], "No term for \(state)")
            #expect(declared[term] == state.code, "No \(term) enumerator")
        }
    }

    @Test("Every state group has a term a script compares against, VM state's own where it shares the word")
    func everyStateGroupHasAnEnumerator() throws {
        let declared = try enumerators("VM state group")
        let states = try enumerators("VM state")

        let terms: [VMStateBucket: String] = [
            .running: "running", .suspended: "suspended", .stopped: "stopped",
            .heldByAnotherCopy: "held by another copy", .preparing: "preparing",
        ]

        #expect(declared.count == VMStateBucket.allCases.count)
        for bucket in VMStateBucket.allCases {
            let term = try #require(terms[bucket], "No term for \(bucket)")
            #expect(declared[term] == VMScriptStateGroup(bucket).code, "No \(term) enumerator")
            if let state = states[term] { #expect(declared[term] == state, "\(term) carries two codes") }
        }
        let suite = try loadSuite()
        #expect(
            try values("class[@name='virtual machine']/property[@name='state group']", "type", in: suite)
                == ["VM state group"])
    }

    @Test("Every way the core can stop a guest has a term a script can name")
    func everyStopDispositionHasAnEnumerator() throws {
        let declared = try enumerators("VM stop method")

        let terms: [VMScriptStopMethod: String] = [.normal: "normal", .anyway: "anyway", .force: "force"]

        #expect(declared.count == StopDisposition.allCases.count)
        #expect(VMScriptStopMethod.allCases.count == StopDisposition.allCases.count)
        #expect(Set(VMScriptStopMethod.allCases.map(\.disposition)) == Set(StopDisposition.allCases))
        for method in VMScriptStopMethod.allCases {
            let term = try #require(terms[method], "No term for \(method)")
            #expect(declared[term] == method.code, "No \(term) enumerator")
        }
    }

    @Test("Every clone outcome has a term a script can name")
    func everyCloneOutcomeHasAnEnumerator() throws {
        let declared = try enumerators("clone outcome")

        let terms: [VMScriptCloneOutcome: String] = [.newMachine: "new machine", .exactCopy: "exact copy"]

        #expect(declared.count == CloneOutcome.allCases.count)
        #expect(Set(VMScriptCloneOutcome.allCases.map(\.outcome)) == Set(CloneOutcome.allCases))
        for outcome in VMScriptCloneOutcome.allCases {
            let term = try #require(terms[outcome], "No term for \(outcome)")
            #expect(declared[term] == outcome.code, "No \(term) enumerator")
        }
    }

    /// Compiles `body` inside a `tell` to this build of the app, whose terms
    /// AppleScript reads from the dictionary in its bundle; nothing is sent.
    @MainActor
    private func compiles(_ body: String) -> Bool {
        let source = "tell application \"\(Bundle.main.bundlePath)\"\n\(body)\nend tell"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        return script.compileAndReturnError(&error)
    }

    @Test(
        "A script names each stop method after method, and the by spelling no longer compiles",
        arguments: ["stop", "restart"])
    @MainActor
    func theStopMethodCompiles(verb: String) {
        #expect(compiles("\(verb) virtual machine \"Alpha\""))
        for term in ["normal", "anyway", "force"] {
            #expect(compiles("\(verb) virtual machine \"Alpha\" method \(term)"), "method \(term)")
        }
        for old in ["by shut down", "by force", "by anyway", "method shut down"] {
            #expect(!compiles("\(verb) virtual machine \"Alpha\" \(old)"), "\(old)")
        }
    }

    @Test("Every kind of named network has a term a script can name")
    func everyNetworkKindHasAnEnumerator() throws {
        let declared = try enumerators("network kind")

        let terms: [VMScriptNetworkKind: String] = [.nat: "nat", .hostOnly: "host only"]

        #expect(declared.count == NetworkKind.allCases.count)
        for kind in NetworkKind.allCases {
            let scriptKind = VMScriptNetworkKind(kind)
            let term = try #require(terms[scriptKind], "No term for \(scriptKind)")
            #expect(declared[term] == scriptKind.code, "No \(term) enumerator")
            #expect(scriptKind.kind == kind)
        }
        let suite = try loadSuite()
        #expect(try values("class[@name='network']/property[@name='kind']", "type", in: suite) == ["network kind"])
    }

    @Test(
        "Every mode a VM's network runs in has a term a script compares against, network kind's own where it shares the word"
    )
    func everyNetworkModeHasAnEnumerator() throws {
        let declared = try enumerators("VM network mode")
        let kinds = try enumerators("network kind")

        let terms: [VMNetworkMode: String] = [.nat: "nat", .bridged: "bridged", .hostOnly: "host only"]

        #expect(declared.count == VMNetworkMode.allCases.count)
        for mode in VMNetworkMode.allCases {
            let term = try #require(terms[mode], "No term for \(mode)")
            #expect(declared[term] == VMScriptNetworkMode(mode).code, "No \(term) enumerator")
            if let kind = kinds[term] { #expect(declared[term] == kind, "\(term) carries two codes") }
        }
        let suite = try loadSuite()
        #expect(
            try values("class[@name='virtual machine']/property[@name='network mode']", "type", in: suite)
                == ["VM network mode"])
    }

    @Test("Every bus a storage disk attaches on has a term a script can compare against")
    func everyStorageDiskKindHasAnEnumerator() throws {
        let declared = try enumerators("storage disk kind")

        // `VMScriptStorageDiskKind` covers every `StorageDiskKind` by an
        // exhaustive switch, so a new bus cannot compile without landing here.
        let terms: [VMScriptStorageDiskKind: String] = [.virtio: "virtio", .usbMassStorage: "USB mass storage"]

        #expect(declared.count == VMScriptStorageDiskKind.allCases.count)
        for kind in VMScriptStorageDiskKind.allCases {
            let term = try #require(terms[kind], "No term for \(kind)")
            #expect(declared[term] == kind.code, "No \(term) enumerator")
        }
        #expect(VMScriptStorageDiskKind(wireName: "virtio") == .virtio)
        #expect(VMScriptStorageDiskKind(wireName: "usbMassStorage") == .usbMassStorage)
        #expect(VMScriptStorageDiskKind(wireName: "scsi") == nil)
        let suite = try loadSuite()
        #expect(
            try values("class[@name='storage disk']/property[@name='kind']", "type", in: suite)
                == ["storage disk kind"])
    }

    @Test("Every kind of snapshot has a term a script can compare against")
    func everySnapshotKindHasAnEnumerator() throws {
        let declared = try enumerators("snapshot kind")

        // `VMScriptSnapshotKind` covers every `VMSnapshotKind` by an exhaustive
        // switch, so a new kind cannot compile without landing here.
        let terms: [VMScriptSnapshotKind: String] = [.warm: "warm", .cold: "cold"]

        #expect(declared.count == VMScriptSnapshotKind.allCases.count)
        for kind in VMScriptSnapshotKind.allCases {
            let term = try #require(terms[kind], "No term for \(kind)")
            #expect(declared[term] == kind.code, "No \(term) enumerator")
        }
        #expect(VMScriptSnapshotKind(wireName: "warm") == .warm)
        #expect(VMScriptSnapshotKind(wireName: "cold") == .cold)
        let suite = try loadSuite()
        #expect(
            try values("class[@name='snapshot']/property[@name='kind']", "type", in: suite) == ["snapshot kind"])
    }
}
