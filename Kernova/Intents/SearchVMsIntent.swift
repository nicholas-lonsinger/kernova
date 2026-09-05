import AppIntents
import Foundation
import KernovaKit

/// Answers a typed search for a virtual machine — Siri's "search for ⟨name⟩ in
/// Kernova" — by revealing the VM whose name the term matches.
///
/// The library has no search field, so the term is resolved the way the entity
/// string query resolves a typed name and the first match is revealed. A term
/// nothing answers to brings the library forward with the selection it already
/// had, which is what a search surface with nothing to show can honestly do.
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
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.revealSearchResult(matching: criteria.term)
        return .result()
    }
}
