import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// Which snapshot a typed argument names, decided from the listing the tool
/// already read rather than by the app.
@Suite("CLI snapshot resolution", .caseScoped)
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

    @Test("A name matches whole, without regard to case")
    func aNameResolves() throws {
        #expect(try resolve("Base", in: [base, older]) == base)
        #expect(try resolve("base", in: [base, older]) == base)
        #expect(try resolve("before upgrade", in: [base, older]) == older)
        #expect(throws: CLIFailure.self) { try resolve("Bas", in: [base, older]) }
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
