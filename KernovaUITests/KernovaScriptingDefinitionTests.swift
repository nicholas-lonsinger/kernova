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

    // MARK: - Well-formedness

    @Test("The dictionary is well-formed against the system's sdef DTD")
    func theDictionaryValidates() throws {
        // After the include, so the Standard Suite the app builds on is
        // validated as part of the document the system actually reads.
        let document = try loadDictionary()
        stripIncludeBases(document)
        try document.validate()
    }

    /// Drops the `xml:base` XInclude stamps every substituted element carries,
    /// which the sdef DTD declares on no element.
    private func stripIncludeBases(_ node: XMLNode) {
        (node as? XMLElement)?.removeAttribute(forName: "xml:base")
        for child in node.children ?? [] { stripIncludeBases(child) }
    }

    @Test("The dictionary builds on the Standard Suite rather than replacing it")
    func theStandardSuiteIsIncluded() throws {
        let suites = try loadDictionary().nodes(forXPath: "/dictionary/suite/@name")
            .compactMap(\.stringValue)

        #expect(suites.contains("Standard Suite"))
        #expect(suites.contains("Kernova Suite"))
    }

    // MARK: - What the dictionary points at

    @Test("Every command the dictionary names is handled by a script command class")
    func everyCommandHasItsHandler() throws {
        let suite = try loadSuite()
        let verbs = try values("command", "name", in: suite)
        #expect(
            Set(verbs)
                == ["start", "stop", "restart", "pause", "resume", "suspend", "reveal"])

        for command in try suite.nodes(forXPath: "command").compactMap({ $0 as? XMLElement }) {
            let handler = try #require(try values("cocoa", "class", in: command).first)
            let handlerClass: AnyClass = try #require(NSClassFromString(handler))
            #expect(handlerClass is NSScriptCommand.Type, "\(handler) is not a script command")
            // Every verb addresses a VM, or a list of them, and the direct
            // parameter is what a script names them with.
            #expect(
                try values("direct-parameter/type", "type", in: command)
                    == ["virtual machine", "virtual machine"])
            #expect(try values("direct-parameter/type", "list", in: command) == ["yes"])
        }
    }

    @Test("Every property of a virtual machine reads a key the object answers to")
    func everyPropertyKeyResolves() throws {
        let classes = try loadSuite().nodes(forXPath: "class[@name='virtual machine']")
        let vm = try #require(classes.first as? XMLElement)
        let properties = try vm.nodes(forXPath: "property").compactMap { $0 as? XMLElement }

        #expect(properties.count == 16, "One property per VMInfo field")
        for property in properties {
            let key = try #require(try values("cocoa", "key", in: property).first)
            #expect(
                VMScriptObject.instancesRespond(to: NSSelectorFromString(key)),
                "VMScriptObject answers to no \(key)")
        }
    }

    @Test("A virtual machine's network membership, network mode and MAC address are writable; the rest read only")
    func theNetworkPropertiesAreWritable() throws {
        let classes = try loadSuite().nodes(forXPath: "class[@name='virtual machine']")
        let vm = try #require(classes.first as? XMLElement)
        let properties = try vm.nodes(forXPath: "property").compactMap { $0 as? XMLElement }
        let writable: Set = ["network membership", "network mode", "MAC address"]

        for property in properties {
            let name = try #require(property.attribute(forName: "name")?.stringValue)
            let access = property.attribute(forName: "access")?.stringValue
            if writable.contains(name) {
                #expect(access == nil, "\(name) is read only")
                let key = try #require(try values("cocoa", "key", in: property).first)
                let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
                #expect(
                    VMScriptObject.instancesRespond(to: NSSelectorFromString(setter)),
                    "VMScriptObject answers to no \(setter)")
            } else {
                #expect(access == "r", "\(name) is writable")
            }
        }
        let names = Set(properties.compactMap { $0.attribute(forName: "name")?.stringValue })
        #expect(writable.isSubset(of: names))
    }

    @Test("Every property and element of a network reads a key the object answers to")
    func everyNetworkKeyResolves() throws {
        let classes = try loadSuite().nodes(forXPath: "class[@name='network']")
        let network = try #require(classes.first as? XMLElement)
        let keyed = try network.nodes(forXPath: "property | element").compactMap { $0 as? XMLElement }

        #expect(keyed.count == 4)
        for node in keyed {
            let key = try #require(try values("cocoa", "key", in: node).first)
            #expect(
                VMNetworkScriptObject.instancesRespond(to: NSSelectorFromString(key)),
                "VMNetworkScriptObject answers to no \(key)")
        }
        // A rename is a `set name`; the kind is fixed when a network is made.
        #expect(try values("property[@name='name']", "access", in: network).isEmpty)
        #expect(try values("property[@name='kind']", "access", in: network) == ["r"])
        #expect(try values("property[@name='id']", "access", in: network) == ["r"])
        #expect(VMNetworkScriptObject.instancesRespond(to: NSSelectorFromString("setName:")))
    }

    @Test("Every property of a storage disk reads a key the object answers to, and none is writable")
    func everyStorageDiskKeyResolves() throws {
        let classes = try loadSuite().nodes(forXPath: "class[@name='storage disk']")
        let disk = try #require(classes.first as? XMLElement)
        let properties = try disk.nodes(forXPath: "property").compactMap { $0 as? XMLElement }

        #expect(disk.attribute(forName: "plural")?.stringValue == "storage disks")
        #expect(properties.count == 8, "One property per StorageDiskSummary field")
        for property in properties {
            let name = try #require(property.attribute(forName: "name")?.stringValue)
            let key = try #require(try values("cocoa", "key", in: property).first)
            #expect(
                VMStorageDiskScriptObject.instancesRespond(to: NSSelectorFromString(key)),
                "VMStorageDiskScriptObject answers to no \(key)")
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

        // `VMScriptState` covers every `VMStatus` by an exhaustive switch, so a
        // new status cannot compile without landing here.
        #expect(declared.count == VMScriptState.allCases.count)
        for state in VMScriptState.allCases {
            #expect(declared[state.term] == state.code, "No \(state.term) enumerator")
        }
    }

    @Test("The state a preparing bundle reports is one of them")
    func preparingIsAState() throws {
        #expect(VMScriptState(wireName: VMStatus.preparingWireName) == .preparing)
        #expect(try enumerators("VM state")["preparing"] == VMScriptState.preparing.code)
    }

    @Test("Every way the core can stop a guest has a term a script can name")
    func everyStopDispositionHasAnEnumerator() throws {
        let declared = try enumerators("VM stop method")

        #expect(declared.count == StopDisposition.allCases.count)
        for disposition in StopDisposition.allCases {
            let method = VMScriptStopMethod(disposition)
            #expect(declared[method.term] == method.code, "No \(method.term) enumerator")
            #expect(method.disposition == disposition)
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

        #expect(declared.count == NetworkKind.allCases.count)
        for kind in NetworkKind.allCases {
            let term = VMScriptNetworkKind(kind)
            #expect(declared[term.term] == term.code, "No \(term.term) enumerator")
            #expect(term.kind == kind)
        }
        let suite = try loadSuite()
        #expect(try values("class[@name='network']/property[@name='kind']", "type", in: suite) == ["network kind"])
    }

    @Test("Every bus a storage disk attaches on has a term a script can compare against")
    func everyStorageDiskKindHasAnEnumerator() throws {
        let declared = try enumerators("storage disk kind")

        // `VMScriptStorageDiskKind` covers every `StorageDiskKind` by an
        // exhaustive switch, so a new bus cannot compile without landing here.
        #expect(declared.count == VMScriptStorageDiskKind.allCases.count)
        for kind in VMScriptStorageDiskKind.allCases {
            #expect(declared[kind.term] == kind.code, "No \(kind.term) enumerator")
        }
        #expect(VMScriptStorageDiskKind(wireName: "virtio") == .virtio)
        #expect(VMScriptStorageDiskKind(wireName: "usbMassStorage") == .usbMassStorage)
        #expect(VMScriptStorageDiskKind(wireName: "scsi") == nil)
        let suite = try loadSuite()
        #expect(
            try values("class[@name='storage disk']/property[@name='kind']", "type", in: suite)
                == ["storage disk kind"])
    }
}
