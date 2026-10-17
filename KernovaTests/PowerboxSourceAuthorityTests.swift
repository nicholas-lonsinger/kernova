import AppKit
import Testing

@testable import Kernova
@testable import KernovaCore

/// Covers ``PowerboxSourceAuthority`` with only the panel's display stood in
/// for.
@Suite("PowerboxSourceAuthority", .caseScoped)
@MainActor
struct PowerboxSourceAuthorityTests {
    @MainActor
    private final class Trace {
        var steps: [String] = []
    }

    @Test("An unreadable file asks the request's requester to activate before its panel, and a dismissal refuses")
    func asksForActivationBeforeThePanel() async {
        let trace = Trace()
        let authority = PowerboxSourceAuthority(present: { _ in
            trace.steps.append("panel")
            return .cancel
        })
        let requester = ActivationRequester { trace.steps.append("activate") }
        // A path nothing can read, so the sandbox's grant is what is asked for.
        let unreadable = URL(filePath: "/nonexistent-\(UUID().uuidString)/Alpha.kernova")

        await ActivationRequester.$current.withValue(requester) {
            await #expect(throws: CommandError.self) {
                try await authority.readableURL(for: unreadable, as: .vmBundle)
            }
        }

        #expect(trace.steps == ["activate", "panel"])
    }
}
