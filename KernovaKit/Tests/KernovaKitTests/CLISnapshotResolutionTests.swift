import Foundation
import KernovaKit
import Testing

@testable import KernovaCLICore

/// Which snapshot a typed argument names, decided from the listing the tool
/// already read rather than by the app.
@Suite("CLI snapshot resolution", .admissionGated)
struct CLISnapshotResolutionTests {
    private let base = SnapshotSummary(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
        name: "Base", notes: "", kind: "warm", createdAt: Date(timeIntervalSince1970: 1_770_000_000),
        isCurrent: true, isEphemeralBaseline: true)
    private let older = SnapshotSummary(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
        name: "Before Upgrade", notes: "", kind: "cold",
        createdAt: Date(timeIntervalSince1970: 1_760_000_000),
        isCurrent: false, isEphemeralBaseline: false)
    private let newer = SnapshotSummary(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID(),
        name: "Before Upgrade", notes: "", kind: "warm",
        createdAt: Date(timeIntervalSince1970: 1_780_000_000),
        isCurrent: false, isEphemeralBaseline: false)

    private func resolve(
        _ text: String, in snapshots: [SnapshotSummary], forcingID: Bool = false
    ) throws -> SnapshotSummary {
        try SnapshotResolution.snapshot(
            named: text, of: "Alpha", in: snapshots, forcingID: forcingID)
    }

    @Test("An identifier names the snapshot carrying it")
    func anIdentifierResolves() throws {
        #expect(try resolve(older.id.uuidString, in: [base, older]) == older)
    }

    @Test("A name matches exactly, and only exactly")
    func aNameResolves() throws {
        #expect(try resolve("Base", in: [base, older]) == base)
        #expect(throws: CLIFailure.self) { try resolve("base", in: [base, older]) }
        #expect(throws: CLIFailure.self) { try resolve("Bas", in: [base, older]) }
    }

    @Test("Text that is an identifier is read as one first, and falls back to the names")
    func anIdentifierWinsOverANameThatLooksLikeOne() throws {
        // A snapshot literally named after another's identifier stays
        // reachable: the identifier match is tried first, the name second.
        let impostor = SnapshotSummary(
            id: newer.id, name: base.id.uuidString, notes: "", kind: "warm",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000), isCurrent: false,
            isEphemeralBaseline: false)
        #expect(try resolve(base.id.uuidString, in: [base, impostor]) == base)
        #expect(try resolve(base.id.uuidString, in: [impostor]) == impostor)
    }

    @Test("A name several snapshots carry refuses, listing each with the identifier that replaces it")
    func anAmbiguousNameListsItsCandidates() {
        do {
            _ = try resolve("Before Upgrade", in: [base, older, newer])
            Issue.record("expected an ambiguity refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .ambiguous)
            #expect(failure.message.contains("Alpha"))
            // One candidate per line, each carrying the identifier a caller
            // retypes — a list a terminal can be read down.
            let lines = failure.message.components(separatedBy: "\n")
            #expect(lines.contains("Before Upgrade (\(older.id.uuidString))"))
            #expect(lines.contains("Before Upgrade (\(newer.id.uuidString))"))
            #expect(!failure.message.contains(base.id.uuidString))
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }

    @Test("A name nothing carries refuses as not found, naming both the snapshot and the VM")
    func anUnknownNameIsNotFound() {
        do {
            _ = try resolve("Missing", in: [base])
            Issue.record("expected a not-found refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .notFound)
            #expect(failure.message.contains("Missing"))
            #expect(failure.message.contains("Alpha"))
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }

    @Test("An empty listing has nothing to resolve to")
    func anEmptyListingResolvesNothing() {
        #expect(throws: CLIFailure.self) { try resolve("Base", in: []) }
        #expect(throws: CLIFailure.self) { try resolve(base.id.uuidString, in: []) }
    }

    @Test("--id resolves by identifier alone, never falling back to a name")
    func forcingTheIdentifierSkipsTheNames() throws {
        #expect(try resolve(base.id.uuidString, in: [base, older], forcingID: true) == base)

        // A snapshot named after another's identifier is not what --id meant.
        let impostor = SnapshotSummary(
            id: newer.id, name: base.id.uuidString, notes: "", kind: "warm",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000), isCurrent: false,
            isEphemeralBaseline: false)
        do {
            _ = try resolve(base.id.uuidString, in: [impostor], forcingID: true)
            Issue.record("expected a not-found refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .notFound)
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }

    @Test("--id on something that is not an identifier is a usage error, not a name search")
    func forcingTheIdentifierRefusesANonIdentifier() {
        do {
            _ = try resolve("Base", in: [base], forcingID: true)
            Issue.record("expected a usage refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .usage)
            #expect(failure.message.contains("Base"))
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }
}
