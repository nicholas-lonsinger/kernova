import Foundation
import KernovaKit
import os

/// Turns a serialized ``VMCommandRequest`` into a facade call and the answer
/// back into a ``VMCommandResponse``.
///
/// The whole wire boundary: it decodes, dispatches, and encodes, and decides
/// nothing else. It depends on ``VMCommanding``, never on the concrete core, so
/// a transport can be driven end to end against a test double.
@MainActor
struct VMCommandEnvelopeRouter {
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VMCommandEnvelopeRouter")

    let commands: any VMCommanding

    init(commands: any VMCommanding) {
        self.commands = commands
    }

    /// Why a payload could not be turned into a command at all.
    enum EnvelopeError: Error, Equatable {
        /// The bytes are not a request this build can read.
        case undecodable(String)
        /// The peer speaks a different version of the vocabulary.
        case unsupportedProtocolVersion(Int)
    }

    // MARK: - Bytes

    /// Answers one encoded request with one encoded response.
    func handle(_ data: Data) async throws -> Data {
        let request: VMCommandRequest
        do {
            request = try JSONDecoder().decode(VMCommandRequest.self, from: data)
        } catch {
            throw EnvelopeError.undecodable(error.localizedDescription)
        }
        guard request.protocolVersion == VMCommandRequest.currentProtocolVersion else {
            throw EnvelopeError.unsupportedProtocolVersion(request.protocolVersion)
        }
        return try JSONEncoder().encode(await respond(to: request))
    }

    // MARK: - Dispatch

    /// Runs one request against the facade.
    ///
    /// A ``CommandError`` becomes a `.failure` result rather than a thrown
    /// error: a refusal is an answer, and every transport has to deliver it.
    func respond(to request: VMCommandRequest) async -> VMCommandResponse {
        do {
            return VMCommandResponse(result: try await dispatch(request.verb))
        } catch let error as CommandError {
            return VMCommandResponse(result: .failure(error.dto))
        } catch {
            Self.logger.error(
                "\(String(describing: request.verb), privacy: .public) failed outside the command vocabulary: \(error.localizedDescription, privacy: .public)"
            )
            return VMCommandResponse(
                result: .failure(
                    .operationFailed(
                        verb: request.verb.verb, message: error.localizedDescription,
                        recovery: nil)))
        }
    }

    private func dispatch(_ verb: VMCommandRequest.Verb) async throws -> VMCommandResponse.Result {
        switch verb {
        case .list:
            return .summaries(commands.list())
        case .info(let selector):
            return .info(try commands.info(selector))
        case .ipAddress(let selector):
            return .ipAddress(try commands.ipAddress(of: selector))
        case .snapshots(let selector):
            return .snapshots(try commands.snapshots(of: selector))

        case .start(let selector, let recovery):
            try await commands.start(selector, recovery: recovery)
            return .ok
        case .stop(let selector, let disposition, let confirmed):
            try await commands.stop(selector, disposition: disposition, confirmed: confirmed)
            return .ok
        case .pause(let selector):
            try await commands.pause(selector)
            return .ok
        case .resume(let selector):
            try await commands.resume(selector)
            return .ok
        case .suspend(let selector):
            try await commands.suspend(selector)
            return .ok
        case .restart(let selector):
            try await commands.restart(selector)
            return .ok
        case .open(let selector):
            try commands.open(selector)
            return .ok

        case .takeSnapshot(let selector, let name, let notes):
            return .snapshot(try await commands.takeSnapshot(selector, name: name, notes: notes))
        case .revertToSnapshot(let selector, let snapshot, let takingCheckpoint, let confirmed):
            try await commands.revertToSnapshot(
                selector, snapshot: snapshot, takingCheckpoint: takingCheckpoint,
                confirmed: confirmed)
            return .ok
        case .deleteSnapshot(let selector, let snapshot, let confirmed):
            try await commands.deleteSnapshot(selector, snapshot: snapshot, confirmed: confirmed)
            return .ok
        case .renameSnapshot(let selector, let snapshot, let newName):
            try commands.renameSnapshot(selector, snapshot: snapshot, to: newName)
            return .ok
        case .setSnapshotNotes(let selector, let snapshot, let notes):
            try commands.setSnapshotNotes(selector, snapshot: snapshot, notes: notes)
            return .ok

        case .clone(let selector, let machineIdentity):
            return .summary(try commands.clone(selector, machineIdentity: machineIdentity))
        case .rename(let selector, let newName):
            try commands.rename(selector, to: newName)
            return .ok
        case .delete(let selector, let permanently, let alsoRemoving, let confirmed):
            try await commands.delete(
                selector, permanently: permanently, alsoRemoving: Set(alsoRemoving),
                confirmed: confirmed)
            return .ok
        case .importVM(let path):
            return .summary(try commands.importVM(from: URL(fileURLWithPath: path)))
        case .cancelPreparing(let selector, let confirmed):
            try commands.cancelPreparing(selector, confirmed: confirmed)
            return .ok
        }
    }

    // MARK: - Events

    /// Every library change as an encoded response, for a transport that
    /// streams them.
    func eventResponses() -> AsyncStream<VMCommandResponse> {
        let events = commands.events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    continuation.yield(VMCommandResponse(result: .event(event)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
