import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// How a delivered URL reads: which route it names, which VM it addresses, and
/// what a link Kernova cannot act on is refused for.
@Suite("Kernova link routes", .admissionGated)
struct VMURLRouteTests {
    private func delivery(_ text: String) throws -> VMURLRoute.Delivery {
        VMURLRoute.delivery(of: try #require(URL(string: text)))
    }

    // MARK: - Routes

    @Test("An open link names the VM to bring forward")
    func openRouteNamesItsVM() throws {
        #expect(try delivery("kernova://open/Sonoma") == .route(.open(.idOrName("Sonoma"))))
    }

    @Test("A reveal link names the VM to put in front of the user")
    func revealRouteNamesItsVM() throws {
        #expect(try delivery("kernova://reveal/Sonoma") == .route(.reveal(.idOrName("Sonoma"))))
    }

    @Test("Each route runs its own verb")
    func eachRouteRunsItsVerb() {
        #expect(VMURLRoute.open(.idOrName("Sonoma")).verb == .open)
        #expect(VMURLRoute.reveal(.idOrName("Sonoma")).verb == .reveal)
    }

    @Test("A percent-encoded name decodes back to what the person wrote")
    func percentEncodedNameDecodes() throws {
        #expect(
            try delivery("kernova://open/My%20VM%20%232")
                == .route(.open(.idOrName("My VM #2"))))
    }

    @Test("An encoded slash stays inside the name instead of splitting it")
    func encodedSlashStaysOneSegment() throws {
        #expect(try delivery("kernova://open/a%2Fb") == .route(.open(.idOrName("a/b"))))
    }

    @Test("A link addresses its VM the way a typed argument does, identifier or name")
    func identifierReadsAsIdOrName() throws {
        let id = UUID()
        #expect(
            try delivery("kernova://open/\(id.uuidString)")
                == .route(.open(.idOrName(id.uuidString))))
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

    // MARK: - Not a link

    @Test("Another scheme is not a link, so the file-open path keeps it")
    func anotherSchemeIsNotALink() throws {
        #expect(try delivery("file:///Users/someone/VMs/Sonoma.kernova") == .notALink)
        #expect(try delivery("https://example.com/open/Sonoma") == .notALink)
    }

    @Test("A delivered batch splits into the links and the files")
    func aMixedBatchSplitsByScheme() throws {
        let bundle = try #require(URL(string: "file:///Users/someone/VMs/Sonoma.kernova"))
        let link = try #require(URL(string: "kernova://open/Sonoma"))
        let (links, files) = VMURLRoute.partition([bundle, link])

        #expect(links == [link])
        #expect(files == [bundle])
    }

    // MARK: - Refusals

    @Test("A bare scheme names no route")
    func bareSchemeNamesNoRoute() throws {
        #expect(try delivery("kernova://") == .refused(.noRoute))
        #expect(try delivery("kernova:") == .refused(.noRoute))
    }

    @Test("A route Kernova does not offer is refused, naming what was asked for")
    func unknownRouteIsRefused() throws {
        #expect(try delivery("kernova://start/Sonoma") == .refused(.unknownRoute("start")))
    }

    @Test("A route naming no VM is refused")
    func routeWithNoVMIsRefused() throws {
        #expect(try delivery("kernova://open") == .refused(.noVM(route: .open)))
        #expect(try delivery("kernova://open/") == .refused(.noVM(route: .open)))
        #expect(try delivery("kernova://reveal") == .refused(.noVM(route: .reveal)))
    }

    @Test("A link carrying more than one VM is refused rather than guessing")
    func extraSegmentsAreRefused() throws {
        #expect(
            try delivery("kernova://open/Sonoma/display")
                == .refused(.extraSegments(route: .open)))
    }

    @Test("Query and fragment are no part of what a link says")
    func queryAndFragmentAreIgnored() throws {
        #expect(
            try delivery("kernova://open/Sonoma?window=new#top")
                == .route(.open(.idOrName("Sonoma"))))
    }

    @Test("A refusal quotes back only enough of the link's own text to recognize it")
    func anUnknownRouteEchoesOnlyAShortPrefix() throws {
        let long = String(repeating: "z", count: 500)
        let delivered = try delivery("kernova://\(long)/Sonoma")

        // The typed case keeps the whole of what was written; only the sentence
        // a person reads is clamped.
        #expect(delivered == .refused(.unknownRoute(long)))
        let message = VMURLRoute.Refusal.unknownRoute(long).message
        #expect(!message.contains(long))
        #expect(message.contains(String(repeating: "z", count: 32) + "\u{2026}"))
        #expect(!message.contains(String(repeating: "z", count: 33)))
    }

    @Test("Every refusal says what is wrong and how a link is written")
    func everyRefusalSaysWhatIsWrong() {
        let refusals: [VMURLRoute.Refusal] = [
            .noRoute, .unknownRoute("start"), .noVM(route: .open), .extraSegments(route: .reveal),
        ]
        for refusal in refusals {
            #expect(refusal.message.contains("kernova:open/"))
        }
        #expect(VMURLRoute.Refusal.unknownRoute("start").message.contains("start"))
        #expect(VMURLRoute.Refusal.noVM(route: .open).message.contains("open"))
        #expect(VMURLRoute.Refusal.extraSegments(route: .reveal).message.contains("reveal"))
    }
}
