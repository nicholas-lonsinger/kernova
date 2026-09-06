import AppIntents
import Foundation

/// Quits Kernova from a Shortcut — the explicit quit that ends a process a
/// Shortcut or the `kernova` tool brought up.
struct QuitKernovaIntent: AppIntent {
    static let title: LocalizedStringResource = "Quit Kernova"
    static let description: IntentDescription? = IntentDescription(
        "Quits Kernova, saving the session of every running or paused virtual machine first.",
        categoryName: "Virtual Machines")

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Quit Kernova")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        await gateway.quit()
        return .result()
    }
}
