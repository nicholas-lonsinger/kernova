import Foundation
import Testing

/// What Shortcuts reads of ``VMEntityQuery`` from the App Intents metadata
/// the build exports, which decides how it runs Find Virtual Machines.
@Suite("VM Entity Query Metadata Tests")
struct VMEntityQueryMetadataTests {
    /// The metadata's query record, as far as Shortcuts reads it to route a
    /// Find.
    private struct Query: Decodable {
        let capabilities: Int
        /// One per property a Find can filter on.
        let parameters: [Parameter]

        struct Parameter: Decodable {}
    }

    private struct Metadata: Decodable {
        let queries: [String: Query]
    }

    /// How Shortcuts runs a Find over a query.
    private enum Route: Equatable {
        /// Fetches every entity and filters and sorts them itself.
        case everyEntity
        /// Sends the filters and the sort to the app's property query.
        case propertyQuery
        /// Neither: a Spotlight query, or no Find to run.
        case other
    }

    /// The capability an `EnumerableEntityQuery` conformance exports: a query
    /// conforming to that alone exports 67 (64 | 2 | 1), one conforming to
    /// `EntityStringQuery` alone 70 (64 | 4 | 2) (Xcode 27B52).
    private static let enumerableCapability = 1

    /// The route WorkflowKit's `WFEntityQueryTypeForQueryMetadata` picks for
    /// `query` (macOS 27.2): the enumerable capability first, then a property
    /// query with any parameter.
    private static func route(of query: Query) -> Route {
        if query.capabilities & enumerableCapability != 0 { return .everyEntity }
        if !query.parameters.isEmpty { return .propertyQuery }
        return .other
    }

    /// The metadata the build exported for this test bundle.
    private static let exported = Bundle(for: BundleToken.self).url(
        forResource: "extract", withExtension: "actionsdata", subdirectory: "Metadata.appintents")

    /// A Find Shortcuts filters itself never reaches the query's conditions:
    /// a shortcut finding VMs by State Group got none on a library of
    /// stopped VMs, and one naming a network or tag Kernova doesn't have gets
    /// none instead of failing — and its next action acts on that set.
    @Test(
        "Shortcuts runs Find Virtual Machines as Kernova's property query",
        .enabled(if: exported != nil, "Xcode's App Intents metadata processor exports it, and swift test runs none"))
    func findRunsThePropertyQuery() throws {
        let url = try #require(Self.exported)
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url))
        let query = try #require(metadata.queries["VMEntityQuery"])

        #expect(Self.route(of: query) == .propertyQuery)
    }
}

/// Names the test bundle, whose resources hold the metadata the build
/// exported for it.
private final class BundleToken {}
