import Cocoa
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The scripting dictionary the app ships, against the code it names.
///
/// The dictionary is data the system reads, so nothing in the app fails to
/// compile when a term stops matching what it points at. These are the checks
/// that would otherwise only fire as a script's "can't get" at runtime.
@Suite("Kernova scripting definition", .admissionGated)
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

    // MARK: - Bundling

    @Test("The app ships the dictionary its Info.plist declares, and turns scripting on")
    func theBundleCarriesTheDictionary() throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool == true)
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String
                == "Kernova.sdef")
        #expect(Bundle.main.url(forResource: "Kernova", withExtension: "sdef") != nil)
    }

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

    @Test("Every class the dictionary names exists under that name in the runtime")
    func everyCocoaClassResolves() throws {
        let named = try values(".//cocoa[@class]", "class", in: try loadSuite())

        #expect(named.contains("VMScriptObject"))
        for name in named {
            #expect(NSClassFromString(name) != nil, "No class is registered as \(name)")
        }
    }

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

    @Test("Every command takes its event over itself: no class is declared to respond to one")
    func noCommandIsDispatchedToItsReceivers() throws {
        // A class declared to respond to a command is one Cocoa dispatches the
        // command to after evaluating its specifier itself — the evaluation
        // each command holds until the library has landed, and the one that
        // answers a duplicate name with "can't get" instead of the core's
        // refusal.
        let suite = try loadSuite()

        #expect(try suite.nodes(forXPath: "class//responds-to").isEmpty)
        for command in try suite.nodes(forXPath: "command").compactMap({ $0 as? XMLElement }) {
            let handler = try #require(try values("cocoa", "class", in: command).first)
            let handlerClass: AnyClass = try #require(NSClassFromString(handler))
            #expect(handlerClass is VMScriptCommand.Type, "\(handler) does not take its event over")
        }
    }

    @Test("The commands that wait on the guest tell a script how to wait longer than AppleScript does")
    func longWaitsAreDocumented() throws {
        let suite = try loadSuite()

        for verb in ["stop", "restart"] {
            let description = try #require(
                try values("command[@name='\(verb)']", "description", in: suite).first)
            #expect(description.contains("with timeout"), "\(verb) says nothing about with timeout")
        }
    }

    @Test("Every property of a virtual machine reads a key the object answers to")
    func everyPropertyKeyResolves() throws {
        let classes = try loadSuite().nodes(forXPath: "class[@name='virtual machine']")
        let vm = try #require(classes.first as? XMLElement)
        let properties = try vm.nodes(forXPath: "property").compactMap { $0 as? XMLElement }

        #expect(properties.count == 15, "One property per VMInfo field")
        for property in properties {
            let key = try #require(try values("cocoa", "key", in: property).first)
            #expect(
                VMScriptObject.instancesRespond(to: NSSelectorFromString(key)),
                "VMScriptObject answers to no \(key)")
        }
    }

    @Test("The application's virtual machines element reads the key the delegate handles")
    func theElementKeyIsTheDelegateKey() throws {
        let extensions = try loadSuite().nodes(
            forXPath: "class-extension[@extends='application']/element[@type='virtual machine']")
        let element = try #require(extensions.first as? XMLElement)

        let key = try #require(try values("cocoa", "key", in: element).first)

        #expect(key == AppDelegate.virtualMachinesKey)
        #expect(AppDelegate.instancesRespond(to: NSSelectorFromString(key)))
        // Cocoa resolves `virtual machine "…"` through the accessor named for
        // that key, and answers with its own case-insensitive first match when
        // there is none — so the spelling is part of the contract.
        #expect(
            AppDelegate.instancesRespond(
                to: NSSelectorFromString("valueInVirtualMachinesWithName:")))
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
}
