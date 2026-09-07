import ArgumentParser
import Foundation
import KernovaKit

/// How a completion reaches Kernova.
///
/// Its own door rather than the one the verbs use. A Tab press never starts the
/// app — nobody pressing it asked for that — and never waits long: a shell that
/// has not come back is worse than a shell offering nothing.
struct CompletionChannel {
    /// Opens a connection to a Kernova that is already running, `nil` when none
    /// is.
    let connect: () throws -> VMCommandClient?

    /// How long one round trip may take.
    let deadline: TimeInterval

    /// What a Tab press actually uses.
    ///
    /// Two seconds, because the wait lands on somebody with a key held down.
    static var live: CompletionChannel {
        CompletionChannel(connect: CommandConnection.openIfRunning, deadline: 2)
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
        guard let subject = CompletionLine.snapshotSubject(in: words, completingAt: index) else {
            return []
        }
        return snapshotNames(ofVM: subject.vm, byIdentifier: subject.byIdentifier)
    }

    /// The settings a `get` key argument offers.
    static let configurationKey = CompletionKind.custom { _, _, _ in configurationKeys() }

    /// The settings a `set` assignment offers, each with the `=` its value
    /// follows.
    ///
    /// Nothing once the word carries an `=`: past that the vocabulary is the
    /// setting's own, and this offers keys.
    static let configurationAssignment = CompletionKind.custom { _, _, prefix in
        prefix.contains("=") ? [] : configurationKeys(suffix: "=")
    }

    // MARK: - The reads behind them

    /// Every virtual machine in the library, by name or — under `--id` — by
    /// identifier.
    static func vmNames(byIdentifier: Bool, over channel: CompletionChannel = .live) -> [String] {
        guard case .summaries(let rows)? = answer(to: .list, over: channel) else { return [] }
        let shell = CompletionShell.requesting
        return rows.map {
            byIdentifier
                ? candidate($0.id.uuidString, describedBy: $0.name, for: shell)
                : candidate($0.name, describedBy: $0.status, for: shell)
        }
    }

    /// Every snapshot of the virtual machine `vm` names, by name or — under
    /// `--id` — by identifier.
    ///
    /// `byIdentifier` reads both arguments the way `--id` does: the machine is
    /// named by identifier, and so is what comes back.
    static func snapshotNames(
        ofVM vm: String, byIdentifier: Bool, over channel: CompletionChannel = .live
    ) -> [String] {
        guard let selector = try? SelectorParsing.selector(from: vm, forcingID: byIdentifier),
            case .snapshots(let listed)? = answer(to: .snapshots(selector), over: channel)
        else { return [] }
        let shell = CompletionShell.requesting
        return listed.map {
            byIdentifier
                ? candidate($0.id.uuidString, describedBy: $0.name, for: shell)
                : candidate($0.name, describedBy: $0.kind, for: shell)
        }
    }

    /// Every setting `get` and `set` address, each with `suffix` appended.
    static func configurationKeys(
        suffix: String = "", over channel: CompletionChannel = .live
    ) -> [String] {
        guard
            case .configurationKeys(let descriptors)? = answer(
                to: .configurationKeys, over: channel)
        else { return [] }
        let shell = CompletionShell.requesting
        return descriptors.map { candidate($0.name + suffix, describedBy: $0.summary, for: shell) }
    }

    /// One round trip, or `nil` for every way one can fail.
    private static func answer(
        to verb: VMCommandRequest.Verb, over channel: CompletionChannel
    ) -> VMCommandResponse.Result? {
        guard let client = (try? channel.connect()) ?? nil else { return nil }
        defer { client.close() }
        client.waitForFrames(upTo: channel.deadline)
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
