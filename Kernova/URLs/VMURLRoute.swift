import Foundation
import KernovaKit

/// One `kernova:` link, read as the verb it names and the VM it addresses.
///
/// A pure function over the URL: the app's URL front door decides nothing about
/// what a link says, so the reading is testable without AppKit and without a
/// command core.
enum VMURLRoute: Equatable {
    /// Bring the VM's display in front of the user.
    case open(VMSelector)
    /// Put the VM in front of the user whatever state it is in.
    case reveal(VMSelector)

    /// The scheme a link this app answers carries.
    static let scheme = "kernova"

    /// Which core verb this route runs.
    var verb: VMVerb {
        switch self {
        case .open: .open
        case .reveal: .reveal
        }
    }

    /// The VM this link addresses, by the same rule a typed CLI argument takes:
    /// an identifier when the text parses as one and names a VM, a display name
    /// otherwise.
    var selector: VMSelector {
        switch self {
        case .open(let selector), .reveal(let selector): selector
        }
    }

    /// Why a `kernova:` link named no route this app answers.
    enum Refusal: Equatable {
        /// The link carried no route at all.
        case noRoute
        /// The link named a route this app does not offer.
        case unknownRoute(String)
        /// The route needs a VM and the link named none.
        case noVM(route: VMVerb)
        /// The link carried more than the one VM the route addresses.
        case extraSegments(route: VMVerb)
    }

    /// How one delivered URL reads.
    enum Delivery: Equatable {
        /// A link this app answers.
        case route(VMURLRoute)
        /// A `kernova:` link this app does not answer.
        case refused(Refusal)
        /// Not a `kernova:` link — the file-open path owns it.
        case notALink
    }

    /// Reads one delivered URL.
    ///
    /// Segments come off `percentEncodedPath`, with the authority as segment
    /// zero: a VM name carrying an encoded `/` stays one segment, and
    /// `kernova:open/<vm>` — the authority-less spelling a person types — needs
    /// no case of its own. A segment that is not valid percent-encoding is kept
    /// as written, so it reaches the user as a VM name nothing answers to
    /// rather than as a second refusal saying the same thing.
    static func delivery(of url: URL) -> Delivery {
        guard isLink(url) else { return .notALink }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .refused(.noRoute)
        }
        let encoded =
            (components.percentEncodedHost.map { [$0] } ?? [])
            + components.percentEncodedPath.split(separator: "/").map(String.init)
        let segments = encoded.map { $0.removingPercentEncoding ?? $0 }.filter { !$0.isEmpty }

        guard let name = segments.first else { return .refused(.noRoute) }
        // A route is spelled with its verb's own wire name, and a URL's
        // authority is case-insensitive, so the route it carries is too.
        let make: (VMSelector) -> VMURLRoute
        let verb: VMVerb
        switch name.lowercased() {
        case VMVerb.open.rawValue: (make, verb) = (VMURLRoute.open, .open)
        case VMVerb.reveal.rawValue: (make, verb) = (VMURLRoute.reveal, .reveal)
        default: return .refused(.unknownRoute(name))
        }

        let rest = segments.dropFirst()
        guard let vm = rest.first else { return .refused(.noVM(route: verb)) }
        guard rest.count == 1 else { return .refused(.extraSegments(route: verb)) }
        return .route(make(.idOrName(vm)))
    }

    /// Splits one delivered batch into the links this front door answers and the
    /// files the import path takes.
    static func partition(_ urls: [URL]) -> (links: [URL], files: [URL]) {
        var links: [URL] = []
        var files: [URL] = []
        for url in urls {
            if isLink(url) {
                links.append(url)
            } else {
                files.append(url)
            }
        }
        return (links, files)
    }

    /// Whether this URL is addressed to the link front door at all.
    private static func isLink(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
    }
}

extension VMURLRoute.Refusal {
    /// The whole refusal, in the words the user reads.
    var message: String {
        switch self {
        case .noRoute:
            "This Kernova link names no route. \(Self.form)"
        case .unknownRoute(let name):
            "Kernova has no link route named \u{201C}\(Self.echoed(name))\u{201D}. \(Self.form)"
        case .noVM(let route):
            "A Kernova \u{201C}\(route.rawValue)\u{201D} link names the virtual machine to \(route.rawValue). \(Self.form)"
        case .extraSegments(let route):
            "A Kernova \u{201C}\(route.rawValue)\u{201D} link names one virtual machine. \(Self.form)"
        }
    }

    /// The two links this app answers, as a person writes them.
    private static let form = "A Kernova link is kernova:open/<name> or kernova:reveal/<name>."

    /// How much of the link's own text a refusal quotes back.
    ///
    /// Whoever wrote the page a link sits on chose its length, so an alert
    /// quotes only enough to recognize what was written. The typed case keeps
    /// the whole of it for anything that needs to match on it.
    private static func echoed(_ text: String) -> String {
        text.count > echoLimit ? String(text.prefix(echoLimit)) + "\u{2026}" : text
    }

    private static let echoLimit = 32
}
