import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import KernovaLoggingMacros

@Suite("#log expansion", .admissionGated)
struct LogMacroTests {
    @Test("A message with no interpolation forwards one literal segment")
    func literalOnly() {
        assertLog(
            ##"#log(Self.logger, .notice, "started")"##,
            expandsTo: ##"""
                {
                    let __logger = Self.logger
                    let __level: KernovaLogLevel = .notice
                    __logger.osLogger.log(level: __level.osLogType, "started")
                    if let __sink = KernovaLogger.forwardingSink {
                        __sink(__level, __logger.subsystem, __logger.category, [LogSegment(text: "started", isPrivate: false)])
                    }
                }()
                """##
        )
    }

    @Test("Explicit .public and .private set the wire segment's privacy")
    func explicitPrivacy() {
        assertLog(
            ##"#log(logger, .info, "a \(x, privacy: .public) b \(y, privacy: .private)")"##,
            expandsTo: ##"""
                {
                    let __logger = logger
                    let __level: KernovaLogLevel = .info
                    __logger.osLogger.log(level: __level.osLogType, "a \(x, privacy: .public) b \(y, privacy: .private)")
                    if let __sink = KernovaLogger.forwardingSink {
                        __sink(__level, __logger.subsystem, __logger.category, [LogSegment(text: "a ", isPrivate: false), LogWire.segment(x, isPrivate: false), LogSegment(text: " b ", isPrivate: false), LogWire.segment(y, isPrivate: true)])
                    }
                }()
                """##
        )
    }

    @Test("An unannotated interpolation lets the LogWire overloads decide")
    func unannotatedPrivacy() {
        assertLog(
            ##"#log(logger, .debug, "n=\(count)")"##,
            expandsTo: ##"""
                {
                    let __logger = logger
                    let __level: KernovaLogLevel = .debug
                    __logger.osLogger.log(level: __level.osLogType, "n=\(count)")
                    if let __sink = KernovaLogger.forwardingSink {
                        __sink(__level, __logger.subsystem, __logger.category, [LogSegment(text: "n=", isPrivate: false), LogWire.segment(count)])
                    }
                }()
                """##
        )
    }

    @Test(".sensitive forwards as private")
    func sensitivePrivacy() {
        assertLog(
            ##"#log(logger, .error, "\(secret, privacy: .sensitive)")"##,
            expandsTo: ##"""
                {
                    let __logger = logger
                    let __level: KernovaLogLevel = .error
                    __logger.osLogger.log(level: __level.osLogType, "\(secret, privacy: .sensitive)")
                    if let __sink = KernovaLogger.forwardingSink {
                        __sink(__level, __logger.subsystem, __logger.category, [LogWire.segment(secret, isPrivate: true)])
                    }
                }()
                """##
        )
    }

    @Test("A format: argument shapes the local emission and never reaches the wire")
    func formatArgumentIsLocalOnly() {
        assertLog(
            ##"#log(logger, .info, "id=\(value, format: .hex, privacy: .public)")"##,
            expandsTo: ##"""
                {
                    let __logger = logger
                    let __level: KernovaLogLevel = .info
                    __logger.osLogger.log(level: __level.osLogType, "id=\(value, format: .hex, privacy: .public)")
                    if let __sink = KernovaLogger.forwardingSink {
                        __sink(__level, __logger.subsystem, __logger.category, [LogSegment(text: "id=", isPrivate: false), LogWire.segment(value, isPrivate: false)])
                    }
                }()
                """##
        )
    }

    @Test("A multi-line literal keeps its indentation stripping and line continuations")
    func multiLineLiteral() {
        assertLog(
            ##"""
            #log(
                logger, .info,
                """
                first \(a, privacy: .public), \
                second
                third
                """)
            """##,
            expandsTo: ##"""
                {
                    let __logger = logger
                    let __level: KernovaLogLevel = .info
                    __logger.osLogger.log(level: __level.osLogType, """
                    first \(a, privacy: .public), \
                    second
                    third
                    """)
                    if let __sink = KernovaLogger.forwardingSink {
                        __sink(__level, __logger.subsystem, __logger.category, [LogSegment(text: "first ", isPrivate: false), LogWire.segment(a, isPrivate: false), LogSegment(text: ", ", isPrivate: false), LogSegment(text: "second\n", isPrivate: false), LogSegment(text: "third", isPrivate: false)])
                    }
                }()
                """##
        )
    }

    @Test("A raw literal's runs are re-emitted between the same delimiters")
    func rawLiteral() {
        assertLog(
            ###"#log(logger, .notice, #"say "hi"\#n\#(name, privacy: .public)"#)"###,
            expandsTo: ###"""
                {
                    let __logger = logger
                    let __level: KernovaLogLevel = .notice
                    __logger.osLogger.log(level: __level.osLogType, #"say "hi"\#n\#(name, privacy: .public)"#)
                    if let __sink = KernovaLogger.forwardingSink {
                        __sink(__level, __logger.subsystem, __logger.category, [LogSegment(text: #"say \#"hi\#"\#n"#, isPrivate: false), LogWire.segment(name, isPrivate: false)])
                    }
                }()
                """###
        )
    }

    @Test("The level may be any KernovaLogLevel expression, chosen at run time")
    func runtimeLevel() {
        assertLog(
            ##"#log(Self.logger, action == .none ? .debug : .info, "decided")"##,
            expandsTo: ##"""
                {
                    let __logger = Self.logger
                    let __level: KernovaLogLevel = action == .none ? .debug : .info
                    __logger.osLogger.log(level: __level.osLogType, "decided")
                    if let __sink = KernovaLogger.forwardingSink {
                        __sink(__level, __logger.subsystem, __logger.category, [LogSegment(text: "decided", isPrivate: false)])
                    }
                }()
                """##
        )
    }

    @Test("A message that is not a literal is a compile-time error")
    func nonLiteralMessageDiagnoses() {
        assertLog(
            ##"#log(logger, .info, text)"##,
            expandsTo: "()",
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "#log's message must be written as a string literal, so os.Logger receives it unchanged",
                    line: 1,
                    column: 21
                )
            ]
        )
    }
}

// MARK: - Harness

/// Expands `original` with the real `#log` implementation and reports any
/// mismatch as a Swift Testing issue.
private func assertLog(
    _ original: String,
    expandsTo expanded: String,
    diagnostics: [DiagnosticSpec] = [],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    assertMacroExpansion(
        original,
        expandedSource: expanded,
        diagnostics: diagnostics,
        macroSpecs: ["log": MacroSpec(type: LogMacro.self)],
        failureHandler: { Issue.record(Comment(rawValue: $0.message), sourceLocation: sourceLocation) }
    )
}
