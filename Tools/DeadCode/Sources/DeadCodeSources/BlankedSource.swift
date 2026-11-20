import SwiftParser
import SwiftSyntax

/// One Swift source file blanked for the source rules, as `dead-code-sources blank` describes the text.
package enum BlankedSource {
    /// `source` blanked, or where it first fails to parse: a file this parser cannot read is refused rather than
    /// blanked in part.
    package static func blank(_ source: UnsafeBufferPointer<UInt8>) -> Result<String, ParseFailure> {
        let tree = Parser.parse(source: source)
        if tree.hasError {
            let error = firstError(in: Syntax(tree))
            // The lexer's own errors, an unterminated comment among them, sit in a token's trivia or text.
            let position =
                if let diagnostic = error.as(TokenSyntax.self)?.tokenDiagnostic {
                    error.position.advanced(by: Int(diagnostic.byteOffset))
                } else {
                    error.positionAfterSkippingLeadingTrivia
                }
            let location = SourceLocationConverter(fileName: "", tree: tree).location(for: position)
            return .failure(ParseFailure(line: location.line, column: location.column))
        }
        var writer = Writer()
        writer.code(Syntax(tree))
        return .success(writer.text)
    }

    /// The innermost node at the first place `node` holds an error: a missing token, a token the lexer rejected, or
    /// text the parser could not place.
    private static func firstError(in node: Syntax) -> Syntax {
        var node = node
        while let child = node.children(viewMode: .all).first(where: \.hasError) {
            node = child
        }
        return node
    }

    private struct Writer {
        var text = ""

        mutating func code(_ node: Syntax) {
            if node.is(StringLiteralExprSyntax.self) || node.is(SimpleStringLiteralExprSyntax.self)
                || node.is(RegexLiteralExprSyntax.self)
            {
                literal(
                    node, first: node.firstToken(viewMode: .sourceAccurate)?.id,
                    last: node.lastToken(viewMode: .sourceAccurate)?.id)
            } else if let token = node.as(TokenSyntax.self) {
                code(token.leadingTrivia)
                if !blankedToken(token) { text += token.text }
                code(token.trailingTrivia)
            } else {
                for child in node.children(viewMode: .sourceAccurate) { code(child) }
            }
        }

        /// The part of a literal at `node`: its delimiters as `"`, its interpolations as `\(` and their code and `)`,
        /// and of everything else only the newlines. `first` and `last` are the literal's outermost tokens, whose
        /// outer trivia is code.
        mutating func literal(_ node: Syntax, first: SyntaxIdentifier?, last: SyntaxIdentifier?) {
            if let segment = node.as(ExpressionSegmentSyntax.self) {
                for token in [segment.backslash, segment.pounds, segment.leftParen].compactMap({ $0 }) {
                    newlines(in: token.leadingTrivia.description)
                    if token.id != segment.leftParen.id { newlines(in: token.trailingTrivia.description) }
                }
                text += "\\("
                code(segment.leftParen.trailingTrivia)
                code(Syntax(segment.expressions))
                code(segment.rightParen.leadingTrivia)
                text += ")"
                newlines(in: segment.rightParen.trailingTrivia.description)
            } else if let token = node.as(TokenSyntax.self) {
                if token.id == first {
                    code(token.leadingTrivia)
                } else {
                    newlines(in: token.leadingTrivia.description)
                }
                if !blankedToken(token) { newlines(in: token.text) }
                if token.id == last {
                    code(token.trailingTrivia)
                } else {
                    newlines(in: token.trailingTrivia.description)
                }
            } else {
                for child in node.children(viewMode: .sourceAccurate) { literal(child, first: first, last: last) }
            }
        }

        /// Writes what stands for `token` when its kind is no code — part of a literal, wherever the parser placed it,
        /// or a shebang line — and returns whether it was.
        mutating func blankedToken(_ token: TokenSyntax) -> Bool {
            switch token.tokenKind {
            case .stringQuote, .multilineStringQuote, .singleQuote, .regexSlash: text += "\""
            case .rawStringPoundDelimiter, .regexPoundDelimiter: break
            case .stringSegment, .regexLiteralPattern: newlines(in: token.text)
            case .shebang: text += " "
            default: return false
            }
            return true
        }

        mutating func code(_ trivia: Trivia) {
            for piece in trivia {
                switch piece {
                case .lineComment, .docLineComment:
                    text += " "
                case .blockComment(let comment), .docBlockComment(let comment):
                    text += " "
                    newlines(in: comment)
                default:
                    piece.write(to: &text)
                }
            }
        }

        mutating func newlines(in string: String) {
            for byte in string.utf8 where byte == UInt8(ascii: "\n") { text += "\n" }
        }
    }
}

/// Where a file stops parsing as Swift, 1-based, the column in UTF-8 bytes.
package struct ParseFailure: Error {
    package var line: Int
    package var column: Int
}
