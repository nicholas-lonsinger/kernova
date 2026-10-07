import AppIntents
import Foundation

/// Answers a typed search for a virtual machine — Siri's "search for ⟨name⟩ in
/// Kernova" — by putting the term in the library's search field and bringing
/// the library forward, the VM the term most likely names selected
/// (``VMLibrary/showSearchResults(for:)``).
@AppIntent(schema: .system.search)
struct SearchVMsIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Virtual Machines"
    static let description: IntentDescription? = IntentDescription(
        "Finds a virtual machine by name and shows it.", categoryName: "Virtual Machines")

    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Search Term")
    var criteria: StringSearchCriteria

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$criteria)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await gateway.showSearchResults(for: criteria.term)
        return .result()
    }
}
