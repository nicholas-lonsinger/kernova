import SwiftParser
import SwiftSyntax

/// What only a build defining `DEBUG` compiles of one Swift source file: code a Debug build has and a Release build
/// leaves out.
///
/// Code is debug-only when a `#if` or `#elseif` clause around it, at any depth, has a condition that cannot hold without
/// `DEBUG`: `DEBUG` itself, an `&&` either side of which is such a condition, or an `||` both sides of which are, with
/// parentheses grouping. A negation counts for nothing, nor does an `#else` clause: `#if !DEBUG`, `#if DEBUG || X`
/// and the `#else` of any `#if` are not debug-only.
package struct DebugOnlyCode {
    /// A declaration named `…ForTesting`, which says it exists for tests alone.
    package struct Seam: Equatable, Sendable {
        package var name: String
        package var line: Int

        package init(name: String, line: Int) {
            self.name = name
            self.line = line
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
        return finder.seams.filter { !Self.isDebugOnly(Syntax($0)) }.map { name in
            Seam(name: name.text, line: converter.location(for: name.positionAfterSkippingLeadingTrivia).line)
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

/// The name of every declaration named `…ForTesting` in a type's body or at file scope, in source order.
private final class SeamFinder: SyntaxVisitor {
    private(set) var seams: [TokenSyntax] = []

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
            seams += names.filter { $0.text.hasSuffix("ForTesting") }
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

package enum SourceError: Error, Equatable, CustomStringConvertible {
    case unparsable(String)

    package var description: String {
        switch self {
        case .unparsable(let path): "\(path) does not parse as Swift, so what only a Debug build compiles is unknown"
        }
    }
}
