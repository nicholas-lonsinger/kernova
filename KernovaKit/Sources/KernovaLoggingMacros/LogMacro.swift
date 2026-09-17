import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expands `#log(logger, level, "…")` into the local `os.Logger` emission plus,
/// when a forwarding sink is installed, the same message as wire segments.
///
/// The message literal reaches `os.Logger` byte for byte, which is what keeps
/// the compiler's `os_log` constant-folding — and with it `logd`-side laziness,
/// per-value privacy and `format:`/`align:` — intact.
public struct LogMacro: ExpressionMacro {
    /// Expands one `#log` call.
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) -> ExprSyntax {
        let arguments = Array(node.arguments)
        guard arguments.count == 3 else {
            context.diagnose(Diagnostic(node: node, message: LogMacroDiagnostic.argumentCount))
            return "()"
        }
        guard let literal = arguments[2].expression.as(StringLiteralExprSyntax.self) else {
            context.diagnose(
                Diagnostic(node: arguments[2].expression, message: LogMacroDiagnostic.messageNotALiteral))
            return "()"
        }

        let logger = arguments[0].expression.trimmedDescription
        let level = arguments[1].expression.trimmedDescription
        let segments = wireSegments(of: literal).joined(separator: ", ")
        return """
            {
                let __logger = \(raw: logger)
                let __level: KernovaLogLevel = \(raw: level)
                __logger.osLogger.log(level: __level.osLogType, \(raw: literal.trimmedDescription))
                if let __sink = KernovaLogger.forwardingSink {
                    __sink(__level, __logger.subsystem, __logger.category, [\(raw: segments)])
                }
            }()
            """
    }

    // MARK: - Wire segments

    /// One `LogSegment` expression per literal run and per interpolation.
    ///
    /// A literal run can be empty — the parser splits segments at every line and
    /// at every escape — and an empty run contributes nothing to the message,
    /// so it stays off the wire.
    private static func wireSegments(of literal: StringLiteralExprSyntax) -> [String] {
        let pounds = literal.openingPounds?.text ?? ""
        return literal.segments.compactMap { segment in
            switch segment {
            case .stringSegment(let run):
                run.content.text.isEmpty
                    ? nil
                    : "LogSegment(text: \(reemitted(run.content.text, pounds: pounds)), isPrivate: false)"
            case .expressionSegment(let interpolation):
                wireSegment(for: interpolation)
            }
        }
    }

    /// The `LogWire.segment` call for one interpolation, dropping the
    /// `format:`/`align:` arguments that only shape the local rendering.
    private static func wireSegment(for interpolation: ExpressionSegmentSyntax) -> String {
        let arguments = Array(interpolation.expressions)
        guard let value = arguments.first?.expression.trimmedDescription else {
            return #"LogSegment(text: "", isPrivate: true)"#
        }
        let privacy = arguments.first { $0.label?.text == "privacy" }?.expression
        switch privacyKind(of: privacy) {
        case .unspecified: return "LogWire.segment(\(value))"
        case .public: return "LogWire.segment(\(value), isPrivate: false)"
        case .private: return "LogWire.segment(\(value), isPrivate: true)"
        }
    }

    /// What a `privacy:` argument asks for on the wire.
    private enum PrivacyKind {
        /// No argument, `.auto`, or an expression this can't read — the
        /// `LogWire.segment` overloads apply `os.Logger`'s own default.
        case unspecified
        case `public`
        case `private`
    }

    /// Reads the leading member name out of `.public`, `.private(mask:)`,
    /// `OSLogPrivacy.sensitive`, and the rest of the `OSLogPrivacy` spellings.
    private static func privacyKind(of expression: ExprSyntax?) -> PrivacyKind {
        let callee = expression?.as(FunctionCallExprSyntax.self)?.calledExpression ?? expression
        guard let name = callee?.as(MemberAccessExprSyntax.self)?.declName.baseName.text else {
            return .unspecified
        }
        switch name {
        case "public": return .public
        case "private", "sensitive": return .private
        default: return .unspecified
        }
    }

    // MARK: - Literal runs

    /// Re-emits one literal run as a string literal of its own.
    ///
    /// The run's source text is copied rather than decoded: written back
    /// between the original delimiters, every escape sequence in it means what
    /// it meant in the original literal. Only what a one-line literal cannot
    /// hold is rewritten — a bare quote, and the newlines a multi-line literal
    /// carries raw (normalized from CR and CRLF the way the compiler
    /// normalizes them).
    private static func reemitted(_ rawText: String, pounds: String) -> String {
        var result = "\(pounds)\""
        var index = rawText.startIndex
        while index < rawText.endIndex {
            let character = rawText[index]
            if character == "\\", let escaped = escapeSequenceEnd(in: rawText, at: index, pounds: pounds) {
                result.append(contentsOf: rawText[index...escaped])
                index = rawText.index(after: escaped)
                continue
            }
            switch character {
            case "\"": result.append("\\\(pounds)\"")
            case "\n": result.append("\\\(pounds)n")
            case "\r":
                result.append("\\\(pounds)n")
                let next = rawText.index(after: index)
                if next < rawText.endIndex, rawText[next] == "\n" { index = next }
            default: result.append(character)
            }
            index = rawText.index(after: index)
        }
        return result + "\"\(pounds)"
    }

    /// The index of the escaped character when `index` starts an escape
    /// sequence, or `nil` when the backslash there is ordinary content — which
    /// is what a backslash not followed by the literal's pounds is.
    private static func escapeSequenceEnd(in text: String, at index: String.Index, pounds: String) -> String.Index? {
        let afterBackslash = text.index(after: index)
        guard text[afterBackslash...].hasPrefix(pounds),
            let escaped = text.index(afterBackslash, offsetBy: pounds.count, limitedBy: text.endIndex),
            escaped < text.endIndex
        else { return nil }
        return escaped
    }
}

// MARK: - Diagnostics

/// The compile-time errors `#log` reports.
enum LogMacroDiagnostic: String, DiagnosticMessage {
    case argumentCount
    case messageNotALiteral

    var message: String {
        switch self {
        case .argumentCount: "#log takes a logger, a level, and a message literal"
        case .messageNotALiteral:
            "#log's message must be written as a string literal, so os.Logger receives it unchanged"
        }
    }

    var diagnosticID: MessageID { MessageID(domain: "KernovaLoggingMacros", id: rawValue) }

    var severity: DiagnosticSeverity { .error }
}
