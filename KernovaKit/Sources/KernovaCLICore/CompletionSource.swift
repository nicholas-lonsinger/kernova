import ArgumentParser
import Foundation
import KernovaKit

/// What one Tab press is answered against: the connection it may open, how long
/// it waits, and the shell that asked.
///
/// Its own door to Kernova rather than the one the verbs use. A Tab press never
/// starts the app — nobody pressing it asked for that — and never waits long: a
/// shell that has not come back is worse than a shell offering nothing.
struct CompletionContext {
    /// Opens a connection to a Kernova that is already running, `nil` when none
    /// is.
    let connect: () throws -> VMCommandClient?

    /// How long one round trip may take.
    let deadline: TimeInterval

    /// The shell waiting for the candidates, which decides how they are
    /// written.
    let shell: CompletionShell?

    /// What a Tab press actually uses.
    ///
    /// Two seconds, because the wait lands on somebody with a key held down.
    static var live: CompletionContext {
        CompletionContext(
            connect: CommandConnection.openIfRunning, deadline: 2,
            shell: CompletionShell.requesting)
    }
}

/// What a Tab press is answered with, asked of the running app.
///
/// Every failure there is — no app listening, a build with no group container
/// to listen in, a selector naming nothing, a deadline — is the same answer: no
/// candidates. Nothing here throws, and nothing here prints into the line the
/// user is typing.
enum CompletionSource {
    // MARK: - What each argument completes to

    /// The virtual machines a `<vm>` argument offers.
    static let vm = CompletionKind.custom { words, index, _ in
        vmNames(byIdentifier: CompletionLine.forcesIdentifiers(in: words, completingAt: index))
    }

    /// The snapshots a `<snapshot>` argument offers, of whichever virtual
    /// machine the line already named.
    static let snapshot = CompletionKind.custom { words, index, _ in
        guard let subject = CompletionLine.vmSubject(in: words, completingAt: index) else {
            return []
        }
        return snapshotNames(ofVM: subject.vm, byIdentifier: subject.byIdentifier)
    }

    /// The folders a `share remove` path argument offers, of whichever virtual
    /// machine the line already named.
    static let sharedDirectory = CompletionKind.custom { words, index, _ in
        guard let subject = CompletionLine.vmSubject(in: words, completingAt: index) else {
            return []
        }
        return sharedDirectoryPaths(ofVM: subject.vm, byIdentifier: subject.byIdentifier)
    }

    /// The mappings a `forward remove` argument offers, of whichever virtual
    /// machine the line already named and on the transport it asked for.
    ///
    /// A rule is addressed by transport as well as by ports, so offering the
    /// other transport's mappings would offer values the verb then refuses.
    static let portMapping = CompletionKind.custom { words, index, _ in
        guard let subject = CompletionLine.vmSubject(in: words, completingAt: index) else {
            return []
        }
        let udp = (subject.command as? KernovaCommand.Forward.Remove)?.udp ?? false
        return portMappings(
            ofVM: subject.vm, byIdentifier: subject.byIdentifier, transport: udp ? .udp : .tcp)
    }

    /// The settings a `get` key argument offers.
    static let configurationKey = CompletionKind.custom { _, _, _ in configurationKeys() }

    /// The settings a `set` assignment offers, each with the `=` its value
    /// follows.
    ///
    /// Nothing once the line is past the key: from there the vocabulary is the
    /// setting's own, and this offers keys.
    static let configurationAssignment = CompletionKind.custom { words, index, prefix in
        guard
            !CompletionLine.isPastAnAssignmentKey(in: words, completingAt: index, prefix: prefix)
        else { return [] }
        return configurationKeys(suffix: "=")
    }

    // MARK: - The reads behind them

    /// Every virtual machine in the library, by name or — under `--id` — by
    /// identifier.
    static func vmNames(byIdentifier: Bool, in context: CompletionContext = .live) -> [String] {
        guard case .summaries(let rows)? = answer(to: .list, in: context) else { return [] }
        return rows.map {
            byIdentifier
                ? candidate($0.id.uuidString, describedBy: $0.name, for: context.shell)
                : candidate($0.name, describedBy: $0.status, for: context.shell)
        }
    }

    /// Every snapshot of the virtual machine `vm` names, by name or — under
    /// `--id` — by identifier.
    ///
    /// `byIdentifier` reads both arguments the way `--id` does: the machine is
    /// named by identifier, and so is what comes back.
    static func snapshotNames(
        ofVM vm: String, byIdentifier: Bool, in context: CompletionContext = .live
    ) -> [String] {
        guard let selector = try? SelectorParsing.selector(from: vm, forcingID: byIdentifier),
            case .snapshots(let listed)? = answer(to: .snapshots(selector), in: context)
        else { return [] }
        return listed.map {
            byIdentifier
                ? candidate($0.id.uuidString, describedBy: $0.name, for: context.shell)
                : candidate($0.name, describedBy: $0.kind, for: context.shell)
        }
    }

    /// Every folder the virtual machine `vm` names shares with its guest, by
    /// the path `share remove` takes back.
    static func sharedDirectoryPaths(
        ofVM vm: String, byIdentifier: Bool, in context: CompletionContext = .live
    ) -> [String] {
        guard let selector = try? SelectorParsing.selector(from: vm, forcingID: byIdentifier),
            case .sharedDirectories(let shares)? = answer(
                to: .sharedDirectories(selector), in: context)
        else { return [] }
        return shares.map {
            candidate(
                $0.path, describedBy: $0.readOnly ? "read-only" : "read-write",
                for: context.shell)
        }
    }

    /// Every mapping the virtual machine `vm` names forwards on `transport`, by
    /// the `<host-port>:<guest-port>` text `forward remove` takes back.
    static func portMappings(
        ofVM vm: String, byIdentifier: Bool, transport: PortForwardingTransport,
        in context: CompletionContext = .live
    ) -> [String] {
        guard let selector = try? SelectorParsing.selector(from: vm, forcingID: byIdentifier),
            case .portForwardingRules(let rules)? = answer(
                to: .portForwardingRules(selector), in: context)
        else { return [] }
        return rules.filter { $0.transport == transport }.map {
            candidate(
                PortMapping.text(for: $0), describedBy: $0.transport.displayName,
                for: context.shell)
        }
    }

    /// Every setting `get` and `set` address, each with `suffix` appended.
    static func configurationKeys(
        suffix: String = "", in context: CompletionContext = .live
    ) -> [String] {
        guard
            case .configurationKeys(let descriptors)? = answer(to: .configurationKeys, in: context)
        else { return [] }
        return descriptors.map {
            candidate($0.name + suffix, describedBy: $0.summary, for: context.shell)
        }
    }

    /// One round trip, or `nil` for every way one can fail.
    private static func answer(
        to verb: VMCommandRequest.Verb, in context: CompletionContext
    ) -> VMCommandResponse.Result? {
        guard let client = (try? context.connect()) ?? nil else { return nil }
        defer { client.close() }
        client.waitForFrames(upTo: context.deadline)
        return try? client.send(verb).payload()
    }

    /// One candidate, carrying its description wherever the requesting shell
    /// shows one.
    ///
    /// zsh hands a custom completion's output to `_describe`, which reads
    /// `value:description` and takes a colon inside the value backslashed. bash
    /// and fish take the bare value.
    static func candidate(
        _ value: String, describedBy description: String, for shell: CompletionShell?
    ) -> String {
        guard shell == .zsh else { return value }
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
        guard !description.isEmpty else { return escaped }
        return "\(escaped):\(description)"
    }
}
