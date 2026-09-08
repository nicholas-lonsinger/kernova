import Foundation
import KernovaKit
import os

/// The `kernova:` link front door: everything a clicked link asks of Kernova
/// passes through here and reaches ``VMCommanding``.
///
/// **Readiness:** a link can be delivered while the app's first library read is
/// still in flight — a cold launch from a link is the ordinary case — and a
/// verb run against a library that has not landed yet refuses with "no virtual
/// machine named…", so every route awaits ``LibraryReadiness`` first.
/// **Addressing:** a
/// link carries text a person wrote, so it addresses VMs by
/// ``VMSelector/idOrName(_:)`` and the ambiguity refusal can fire here.
///
/// It presents its own refusals, unlike ``VMIntentGateway``: a link has nobody
/// to answer to, so the app is the only place its refusal can land — and it
/// summons the library to land it in, because an alert with no window to show
/// in is one the person only meets later, stale, when they next open Kernova.
@MainActor
final class VMURLGateway {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMURLGateway")

    private let commands: any VMCommanding
    /// The app's first library read, shared with every other front door.
    private let readiness: LibraryReadiness
    /// Brings the app forward for a surface something outside the process asked
    /// for.
    private let activate: @MainActor () -> Void
    /// Puts the library window on screen, which is where an alert is shown.
    private let summonLibrary: @MainActor () -> Void
    /// Shows the user what a link was refused for.
    private let present: @MainActor (CommandError) -> Void

    init(
        commands: any VMCommanding,
        readiness: LibraryReadiness,
        activate: @escaping @MainActor () -> Void,
        summonLibrary: @escaping @MainActor () -> Void,
        present: @escaping @MainActor (CommandError) -> Void
    ) {
        self.commands = commands
        self.readiness = readiness
        self.activate = activate
        self.summonLibrary = summonLibrary
        self.present = present
    }

    /// Answers one `kernova:` link: waits for the first library read, brings the
    /// app forward, runs the verb, and shows whatever it refused.
    ///
    /// Only a route waits for the library read — what a link *says* is decided
    /// by the URL alone, so a link naming no route Kernova offers is refused
    /// straight away.
    func handle(_ url: URL) async {
        switch VMURLRoute.delivery(of: url) {
        case .notALink:
            Self.logger.fault("A URL carrying no Kernova link reached the link front door")
            assertionFailure("A URL carrying no Kernova link reached the link front door: \(url)")
        case .refused(let refusal):
            Self.logger.notice("Refused a Kernova link: \(refusal.message, privacy: .public)")
            activate()
            surface(.invalidArgument(refusal.message))
        case .route(let route):
            Self.logger.notice(
                "Kernova link asks \(route.verb.rawValue, privacy: .public) of '\(route.selector.displayText, privacy: .private)'"
            )
            await readiness.ready()
            // Before the verb, so the window it surfaces opens in front of the
            // person who clicked rather than behind whatever they clicked in.
            activate()
            run(route)
        }
    }

    /// Runs the route's verb, surfacing whatever it refused.
    ///
    /// Nothing is summoned when the verb runs: it puts on screen exactly the
    /// surface the link asked for, and a library window behind that is one
    /// nobody asked for.
    private func run(_ route: VMURLRoute) {
        do {
            switch route {
            case .open(let selector): try commands.open(selector)
            case .reveal(let selector): try commands.reveal(selector)
            }
        } catch let refusal as CommandError {
            surface(refusal)
        } catch {
            surface(.operationFailed(verb: route.verb, message: error.localizedDescription))
        }
    }

    /// Puts a refusal where the person who clicked can read it.
    ///
    /// The library comes up first because that is what an alert is shown in:
    /// the app answers a link in every state it can be in — headless with only
    /// the status item up, or launching with no window built yet — and in both
    /// the refusal would otherwise wait, buffered, for a window the person has
    /// no reason to open, arriving stale whenever they next did.
    private func surface(_ refusal: CommandError) {
        summonLibrary()
        present(refusal)
    }
}
