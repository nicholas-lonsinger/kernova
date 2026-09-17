import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// The compiler plugin `KernovaLogging`'s macro declarations resolve against.
@main
struct KernovaLoggingPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [LogMacro.self]
}
