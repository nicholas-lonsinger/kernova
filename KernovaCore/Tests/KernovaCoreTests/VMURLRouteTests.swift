import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// How a delivered URL reads: which route it names, which VM it addresses, and
/// what a link Kernova cannot act on is refused for.
@Suite("Kernova link routes", .caseScoped)
struct VMURLRouteTests {
    private func delivery(_ text: String) throws -> VMURLRoute.Delivery {
        VMURLRoute.delivery(of: try #require(URL(string: text)))
    }

    // MARK: - Routes

    @Test("An encoded slash stays inside the name instead of splitting it")
    func encodedSlashStaysOneSegment() throws {
        #expect(try delivery("kernova://open/a%2Fb") == .route(.open(.idOrName("a/b"))))
    }

    @Test("The route name and the scheme are both case-insensitive")
    func routeNameIsCaseInsensitive() throws {
        #expect(try delivery("kernova://OPEN/Sonoma") == .route(.open(.idOrName("Sonoma"))))
        #expect(try delivery("KERNOVA://open/Sonoma") == .route(.open(.idOrName("Sonoma"))))
    }

    @Test("The authority slashes are optional — the route can lead the path")
    func authorityIsOptional() throws {
        #expect(try delivery("kernova:open/Sonoma") == .route(.open(.idOrName("Sonoma"))))
        #expect(try delivery("kernova:reveal/Sonoma") == .route(.reveal(.idOrName("Sonoma"))))
    }
}
