import AppKit
import Testing

@MainActor
struct ScriptingDefinitionTests {
    @Test func theHostLoadsKernovasDictionary() throws {
        #expect(NSScriptSuiteRegistry.shared().suiteNames.contains("Kernova Suite"))

        let application = try #require(NSScriptClassDescription(for: NSApplication.self))
        #expect(application.toManyRelationshipKeys.contains("virtualMachines"))
        #expect(application.toManyRelationshipKeys.contains("networks"))
    }
}
