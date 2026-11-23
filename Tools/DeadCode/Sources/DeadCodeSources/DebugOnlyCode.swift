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

package enum SourceError: Error, Equatable, CustomStringConvertible {
    case unparsable(String)

    package var description: String {
        switch self {
        case .unparsable(let path): "\(path) does not parse as Swift, so what only a Debug build compiles is unknown"
        }
    }
}
