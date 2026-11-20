import DeadCodeKit
import DeadCodeSources
import Foundation
import Testing

/// The one declaration in `"\(condition)\nvar x = 0\n#endif\n"`, at line 2 column 5.
private func declarationIsDebugOnly(under condition: String) throws -> Bool {
    try DebugOnlyCode(path: "A.swift", source: "\(condition)\nvar x = 0\n#endif\n").contains(line: 2, column: 5)
}

@Suite struct DebugOnlyCodeTests {
    /// `DEBUG`, an `&&` with such a side, or an `||` with two; a negation counts for nothing, so `!(!DEBUG)`, which
    /// needs `DEBUG`, is not debug-only.
    @Test(arguments: [
        ("#if DEBUG", true),
        ("#if os(Linux) && DEBUG", true),
        ("#if (DEBUG)", true),
        ("#if DEBUG && (os(macOS) || os(Linux))", true),
        ("#if (DEBUG && os(macOS)) || (os(Linux) && DEBUG)", true),
        ("#if DEBUG // a comment", true),
        ("#if !DEBUG", false),
        ("#if DEBUG || os(Linux)", false),
        ("#if os(Linux) || DEBUG && os(macOS)", false),
        ("#if !(!DEBUG)", false),
        ("#if DEBUGGING", false),
        ("#if os(Linux)", false),
    ])
    func aClauseIsDebugOnlyWhenItsConditionHasTheRulesShape(condition: String, debugOnly: Bool) throws {
        #expect(try declarationIsDebugOnly(under: condition) == debugOnly)
    }

    /// The condition of a `#elseif` is its own; an `#else` clause has none, whatever the `#if` it follows tests.
    @Test func eachClauseIsJudgedByItsOwnCondition() throws {
        let source = """
            struct S {
                #if os(Linux)
                var linux = 0
                #elseif DEBUG
                var debug = 0
                #else
                var otherwise = 0
                #endif
                #if !DEBUG
                var release = 0
                #else
                var notRelease = 0
                #endif
                var after = 0
            }
            """
        let code = try DebugOnlyCode(path: "S.swift", source: source)
        #expect(!code.contains(line: 3, column: 9))
        #expect(code.contains(line: 5, column: 9))
        #expect(!code.contains(line: 7, column: 9))
        #expect(!code.contains(line: 10, column: 9))
        #expect(!code.contains(line: 12, column: 9))
        #expect(!code.contains(line: 14, column: 9))
    }

    @Test func aDebugOnlyClauseCoversEverythingNestedInIt() throws {
        let source = """
            #if os(Linux)
            struct Bus {
                #if DEBUG
                func observeForTesting() {
                    #if canImport(Glibc)
                    let x = 0
                    #endif
                }
                #endif
                func close() {}
            }
            #endif
            """
        let code = try DebugOnlyCode(path: "Bus.swift", source: source)
        #expect(!code.contains(line: 2, column: 8))
        #expect(code.contains(line: 4, column: 10))
        #expect(code.contains(line: 6, column: 13))
        #expect(!code.contains(line: 10, column: 10))
    }

    /// An import is reported at column 1, which is indentation when the import is indented.
    @Test func anIndentedImportIsJudgedFromItsFirstColumn() throws {
        let source = """
            enum E {}
            #if DEBUG
                import Testing
            #endif
            """
        #expect(try DebugOnlyCode(path: "E.swift", source: source).contains(line: 3, column: 1))
    }

    /// What reads as a directive only in a comment or a string is not one.
    @Test func aDirectiveIsReadFromTheSyntaxNotTheText() throws {
        let source = #"""
            /*
            #if DEBUG
            */
            var commented = 0
            let text = """
            #if DEBUG
            """
            var quoted = 0
            /*
            #endif
            */
            """#
        let code = try DebugOnlyCode(path: "T.swift", source: source)
        #expect(!code.contains(line: 4, column: 5))
        #expect(!code.contains(line: 8, column: 5))
    }

    @Test func aFileThatDoesNotParseIsRefused() {
        #expect(throws: SourceError.unparsable("Broken.swift")) {
            try DebugOnlyCode(path: "Broken.swift", source: "struct S {\n#if DEBUG\nvar x = 0\n}\n")
        }
    }
}

/// A condition over `DEBUG` and two other flags, negation on an atom only, rendered as `#if` spells it.
private indirect enum Condition: CustomStringConvertible, Sendable {
    case flag(String)
    case not(String)
    case and(Condition, Condition)
    case or(Condition, Condition)

    static let atoms: [Condition] = [.flag("DEBUG"), .flag("A"), .flag("B"), .not("DEBUG"), .not("A")]

    func holds(_ defined: Set<String>) -> Bool {
        switch self {
        case .flag(let name): defined.contains(name)
        case .not(let name): !defined.contains(name)
        case .and(let lhs, let rhs): lhs.holds(defined) && rhs.holds(defined)
        case .or(let lhs, let rhs): lhs.holds(defined) || rhs.holds(defined)
        }
    }

    /// Whether some build that leaves `DEBUG` undefined satisfies it.
    var holdsWithoutDEBUG: Bool {
        [[], ["A"], ["B"], ["A", "B"]].contains { holds(Set($0)) }
    }

    /// Parenthesised only where `&&` binding tighter than `||` needs it.
    var description: String {
        switch self {
        case .flag(let name): name
        case .not(let name): "!\(name)"
        case .and(let lhs, let rhs): "\(lhs.operand) && \(rhs.operand)"
        case .or(let lhs, let rhs): "\(lhs) || \(rhs)"
        }
    }

    /// Every operator parenthesised.
    var grouped: String {
        switch self {
        case .flag, .not: description
        case .and(let lhs, let rhs): "(\(lhs.grouped) && \(rhs.grouped))"
        case .or(let lhs, let rhs): "(\(lhs.grouped) || \(rhs.grouped))"
        }
    }

    private var operand: String {
        if case .or = self { return "(\(self))" }
        return description
    }
}

@Suite struct DebugOnlySoundnessTests {
    /// Every condition of up to two operators over the atoms: one judged debug-only is false in every build without
    /// `DEBUG`, so nothing a Release build compiles is left out of the release view.
    @Test func noConditionABuildWithoutDEBUGSatisfiesIsDebugOnly() throws {
        let one =
            Condition.atoms
            + Condition.atoms.flatMap { lhs in
                Condition.atoms.flatMap { rhs in [Condition.and(lhs, rhs), .or(lhs, rhs)] }
            }
        let two = one.flatMap { lhs in
            Condition.atoms.flatMap { rhs in [Condition.and(lhs, rhs), .or(lhs, rhs), .and(rhs, lhs), .or(rhs, lhs)] }
        }
        var debugOnly = 0
        for condition in one + two {
            for spelling in [condition.description, condition.grouped] {
                let judged = try declarationIsDebugOnly(under: "#if \(spelling)")
                if judged {
                    debugOnly += 1
                    #expect(!condition.holdsWithoutDEBUG, "#if \(spelling)")
                }
            }
        }
        // The rule is not vacuous: `DEBUG`, `DEBUG && A`, `A && DEBUG`, … are judged debug-only.
        #expect(debugOnly > 0)
    }
}

@Suite struct ReleaseViewTests {
    private let sources = [
        "Kit.swift": """
        struct Kit {
            #if DEBUG
            var seamForTesting = 0
            var deadSeamForTesting = 0
            #endif
            var testedOnly = 0
            #if DEBUG || os(Linux)
            var either = 0
            #endif
            #if !DEBUG
            var release = 0
            #else
            var otherwise = 0
            #endif
        }
        """,
        "Bus.swift": """
        #if os(Linux)
        struct Bus {
            #if DEBUG
            func observeForTesting() {}
            #endif
            func close() {}
        }
        #endif
        """,
    ]

    private func finding(_ location: String, _ name: String) -> Finding {
        Finding(kind: "var.instance", name: name, hints: ["unused"], location: parsed(location), ids: [])
    }

    /// Both platforms compile Kit.swift; only Linux compiles Bus.swift. Each platform's full scan reports what nothing
    /// uses, and its production scan everything the test targets alone use besides.
    private func report() throws -> DeadCodeReport {
        let dead = [finding("Kit.swift:4:9", "deadSeamForTesting")]
        let kit =
            dead + [
                finding("Kit.swift:3:9", "seamForTesting"), finding("Kit.swift:6:9", "testedOnly"),
                finding("Kit.swift:8:9", "either"), finding("Kit.swift:13:9", "otherwise"),
            ]
        let bus = [finding("Bus.swift:4:10", "observeForTesting()"), finding("Bus.swift:6:10", "close()")]
        let source = { (path: String) throws -> String in
            try #require(sources[path], "no source for \(path)")
        }
        let macos = try PlatformBundle(
            full: dead, production: kit, presence: Presence(keys: Set(kit.map(\.key))), source: source)
        let linux = try PlatformBundle(
            full: dead, production: kit + bus, presence: Presence(keys: Set((kit + bus).map(\.key))), source: source)
        return try DeadCodeReport(bundles: [(.macos, macos), (.linux, linux)])
    }

    @Test func aDebugOnlyDeclarationOnlyTestsReachIsNotListed() throws {
        let report = try report()
        #expect(!report.testOnly.map(\.name).contains("seamForTesting"))
        #expect(!report.testOnly.map(\.name).contains("observeForTesting()"))
    }

    /// `#if DEBUG || os(Linux)` and the `#else` of `#if !DEBUG` are not debug-only, whatever a build of either does.
    @Test func aDeclarationOutsideEveryDebugOnlyClauseIsListed() throws {
        let report = try report()
        #expect(report.testOnly.map(\.name) == ["close()", "testedOnly", "either", "otherwise"])
        #expect(report.testOnly.first?.compiledOnly(among: [.macos, .linux]) == [.linux])
    }

    @Test func aDebugOnlyDeclarationNothingReachesIsStillDead() throws {
        #expect(try report().dead.map(\.name) == ["deadSeamForTesting"])
    }
}

@Suite struct UngatedSeamsTests {
    @Test func aSeamIsAMemberOrFileScopeDeclarationOutsideEveryDebugOnlyClause() throws {
        let source = """
            struct S {
                var shippedForTesting = 0
                #if DEBUG
                var gatedForTesting = 0
                #else
                var elseForTesting = 0
                #endif
                #if DEBUG || os(Linux)
                func eitherForTesting() {}
                #endif
                #if !DEBUG
                func releaseForTesting() {}
                #endif
                func f(parameterForTesting: Int) {
                    let localForTesting = parameterForTesting
                    if let boundForTesting = Optional(localForTesting) { _ = boundForTesting }
                }
                enum E { case caseForTesting }
                let (tupleForTesting, other) = (0, 0)
                struct Inner { static var innerForTesting: Int { 0 } }
                var hookForTestingOnly = 0
                var `escapedForTesting` = 0
            }
            #if DEBUG
            extension S { func wholeForTesting() {} }
            #endif
            func topLevelForTesting() {}
            typealias AliasForTesting = Int
            protocol ProtocolForTesting { func requirementForTesting() }
            """
        let seams = try DebugOnlyCode(path: "S.swift", source: source).ungatedSeams
        #expect(
            seams.map { "\($0.line) \($0.name)" } == [
                "2 shippedForTesting", "6 elseForTesting", "9 eitherForTesting", "12 releaseForTesting",
                "18 caseForTesting", "19 tupleForTesting", "20 innerForTesting", "21 hookForTestingOnly",
                "22 escapedForTesting", "27 topLevelForTesting", "28 AliasForTesting", "29 ProtocolForTesting",
                "29 requirementForTesting",
            ])
        #expect(seams.first?.text == "var shippedForTesting = 0")
        #expect(seams.first { $0.name == "escapedForTesting" }?.text == "var `escapedForTesting` = 0")
    }

    /// A line ends at `\r\n`, `\n` or a lone `\r`, as the compiler counts lines.
    @Test(arguments: ["\r\n", "\n", "\r"])
    func aSeamIsReportedWithItsLineWhateverEndsTheLines(end: String) throws {
        let source = ["struct S {", "    // A comment.", "    var shippedForTesting = 0", "}", ""].joined(
            separator: end)
        #expect(
            try DebugOnlyCode(path: "S.swift", source: source).ungatedSeams == [
                .init(name: "shippedForTesting", line: 3, text: "var shippedForTesting = 0")
            ])
    }
}
