import SwiftParser
import SwiftSyntax

/// One Swift source file, read for its debug-only code: code that cannot compile without `DEBUG`, so no Release build
/// holds it.
///
/// The reading is conservative. Everything it calls debug-only needs `DEBUG`, but not all code that needs `DEBUG` is
/// called debug-only. Code is debug-only when a `#if` or `#elseif` clause around it, at any depth, has a condition of
/// this shape: `DEBUG` itself, an `&&` either side of which has this shape, or an `||` both sides of which do, with
/// parentheses grouping. A negation counts for nothing, nor does an `#else` clause. So `#if !DEBUG`, `#if DEBUG || X`
/// and the `#else` of any `#if` are not debug-only, even the `#else` of `#if !DEBUG`.
package struct DebugOnlyCode {
    /// A declaration whose name contains `ForTesting`, which says it exists for tests alone.
    package struct Seam: Equatable, Sendable {
        package var name: String
        package var line: Int
        /// The line the name is on, without its indentation.
        package var text: String

        package init(name: String, line: Int, text: String) {
            self.name = name
            self.line = line
            self.text = text
        }
    }

    private let tree: SourceFileSyntax
    private let converter: SourceLocationConverter

    /// `source`, the text of `path`, which must parse without error: a file this parser cannot read is refused rather
    /// than read wrongly.
    package init(path: String, source: String) throws(SourceError) {
        tree = Parser.parse(source: source)
        guard !tree.hasError else { throw .unparsable(path) }
        converter = SourceLocationConverter(fileName: path, tree: tree)
    }

    /// Whether the code at `line` and `column`, 1-based with the column in UTF-8 bytes as an index store records a
    /// location, is debug-only.
    package func contains(line: Int, column: Int) -> Bool {
        guard let token = tree.token(at: converter.position(ofLine: line, column: column)) else { return false }
        return Self.isDebugOnly(Syntax(token))
    }

    /// Every seam a Release build compiles: one declared in a type's body or at file scope, outside all debug-only code.
    /// A local, declared in a function or closure body, is not a seam.
    package var ungatedSeams: [Seam] {
        let finder = SeamFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        // Lines as the converter counts them, which ends one at `\r\n`, `\n` or a lone `\r`.
        let lines = converter.sourceLines
        return finder.seams.filter { !Self.isDebugOnly(Syntax($0.token)) }.map { seam in
            let line = converter.location(for: seam.token.positionAfterSkippingLeadingTrivia).line
            return Seam(name: seam.name, line: line, text: lines[line - 1].trimmed)
        }
    }

    private static func isDebugOnly(_ node: Syntax) -> Bool {
        var ancestor = node.parent
        while let current = ancestor {
            if let condition = current.as(IfConfigClauseSyntax.self)?.condition, needsDEBUG(condition) { return true }
            ancestor = current.parent
        }
        return false
    }

    private static func needsDEBUG(_ condition: ExprSyntax) -> Bool {
        if let reference = condition.as(DeclReferenceExprSyntax.self) { return reference.baseName.text == "DEBUG" }
        if let group = condition.as(TupleExprSyntax.self), group.elements.count == 1, let only = group.elements.first {
            return needsDEBUG(only.expression)
        }
        // The parser leaves `a && b || c` unfolded; `||` binds loosest, so it is the `||` of its runs of `&&`.
        if let sequence = condition.as(SequenceExprSyntax.self) {
            var alternatives: [[ExprSyntax]] = [[]]
            for element in sequence.elements {
                guard let symbol = element.as(BinaryOperatorExprSyntax.self)?.operator.text else {
                    alternatives[alternatives.count - 1].append(element)
                    continue
                }
                switch symbol {
                case "&&": break
                case "||": alternatives.append([])
                default: return false
                }
            }
            return alternatives.allSatisfy { $0.contains(where: needsDEBUG) }
        }
        return false
    }
}

/// Every declaration in a type's body or at file scope whose name, backticks aside, contains `ForTesting`, in source
/// order.
private final class SeamFinder: SyntaxVisitor {
    private(set) var seams: [(token: TokenSyntax, name: String)] = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { record([node.name], of: node) }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { record([node.name], of: node) }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { record([node.name], of: node) }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { record([node.name], of: node) }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { record([node.name], of: node) }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { record([node.name], of: node) }
    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { record([node.name], of: node) }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.elements.map(\.name), of: node)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.bindings.flatMap { Self.names(in: $0.pattern) }, of: node)
    }

    private func record(_ names: [TokenSyntax], of declaration: some DeclSyntaxProtocol) -> SyntaxVisitorContinueKind {
        if Self.isMemberOrFileScope(Syntax(declaration)) {
            for token in names {
                let name = token.identifier?.name ?? token.text
                if name.contains("ForTesting") { seams.append((token, name)) }
            }
        }
        return .visitChildren
    }

    private static func names(in pattern: PatternSyntax) -> [TokenSyntax] {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) { return [identifier.identifier] }
        if let tuple = pattern.as(TuplePatternSyntax.self) { return tuple.elements.flatMap { names(in: $0.pattern) } }
        return []
    }

    /// A declaration whose nearest enclosing scope, through any `#if`, is a type's body or the file.
    private static func isMemberOrFileScope(_ declaration: Syntax) -> Bool {
        var node = declaration
        while let parent = node.parent {
            switch parent.kind {
            case .memberBlock, .sourceFile: return true
            case .codeBlockItem, .codeBlockItemList, .memberBlockItem, .memberBlockItemList, .ifConfigClause,
                .ifConfigClauseList, .ifConfigDecl:
                node = parent
            default: return false
            }
        }
        return false
    }
}

extension String {
    /// This string without the whitespace and line terminators at either end.
    fileprivate var trimmed: String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}

package enum SourceError: Error, Equatable, CustomStringConvertible {
    case unparsable(String)

    package var description: String {
        switch self {
        case .unparsable(let path): "\(path) does not parse as Swift, so what only a Debug build compiles is unknown"
        }
    }
}
