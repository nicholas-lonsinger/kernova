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

    // MARK: - Bytes

    /// Reads one encoded request, or the refusal a transport delivers in its
    /// place.
    ///
    /// An envelope refusal is a frame, not a thrown error: the peer asked a
    /// question and is owed an answer, and only the transport can send one.
    nonisolated func decode(_ data: Data) -> Result<VMCommandRequest, VMCommandTransportRefusal> {
        let request: VMCommandRequest
        do {
            request = try JSONDecoder().decode(VMCommandRequest.self, from: data)
        } catch {
            return .failure(.undecodableRequest(error.localizedDescription))
        }
        guard request.protocolVersion == VMCommandRequest.currentProtocolVersion else {
            return .failure(
                .unsupportedProtocolVersion(
                    peer: request.protocolVersion,
                    expected: VMCommandRequest.currentProtocolVersion))
        }
        return .success(request)
    }

    /// Serializes one response for the wire.
    nonisolated func encode(_ response: VMCommandResponse) -> Data {
        do {
            return try JSONEncoder().encode(response)
        } catch {
            // Every payload is a `Codable` value this module owns, so nothing
            // here has an encodable shape that can fail at runtime.
            Self.logger.fault(
                "A response could not be encoded: \(error.localizedDescription, privacy: .public)")
            assertionFailure("A response could not be encoded: \(error)")
            let fallback = VMCommandResponse(
                result: .failure(
                    .operationFailed(
                        verb: .list, title: nil,
                        message: "The answer could not be encoded.", recovery: nil)))
            return (try? JSONEncoder().encode(fallback)) ?? Data()
        }
    }

    /// Answers one encoded request with one encoded response.
    ///
    /// The unary round trip, for a caller holding whole payloads rather than a
    /// stream. A subscription goes through ``snapshotAndEvents()`` instead.
    func handle(_ data: Data) async -> Data {
        switch decode(data) {
        case .failure(let refusal):
            return encode(VMCommandResponse(result: .refused(refusal)))
        case .success(let request):
            return encode(await respond(to: request))
        }
    }

    // MARK: - Subscription

    /// The library as it stands, and every change from that instant on.
    ///
    /// Subscribes *before* it lists, both inside this one main-actor call, so
    /// no event can land between the two and be lost. That is what makes a
    /// client waiting for a state race-free against a VM already in it.
    func snapshotAndEvents() -> (VMCommandResponse, AsyncStream<VMCommandResponse>) {
        let events = eventResponses()
        let snapshot = VMCommandResponse(result: .summaries(commands.list()))
        return (snapshot, events)
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
                        verb: request.verb.verb, title: nil,
                        message: error.localizedDescription, recovery: nil)))
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
        case .events:
            // Streaming, not unary: a transport answers `.events` through
            // `snapshotAndEvents()` and never reaches here.
            assertionFailure("The events verb was dispatched as a unary request")
            return .failure(
                .operationFailed(
                    verb: .events, title: nil,
                    message: "This transport does not deliver event subscriptions.",
                    recovery: nil))

        case .start(let selector, let recovery, let presentation):
            try await commands.start(selector, recovery: recovery, presentation: presentation)
            return .ok
        case .cancelGuestSetup(let selector, let confirmed):
            try commands.cancelGuestSetup(selector, confirmed: confirmed)
            return .ok
        case .stop(let selector, let disposition, let confirmed):
            try await commands.stop(selector, disposition: disposition, confirmed: confirmed)
            return .ok
        case .pause(let selector):
            try await commands.pause(selector)
            return .ok
        case .resume(let selector, let presentation):
            try await commands.resume(selector, presentation: presentation)
            return .ok
        case .suspend(let selector):
            try await commands.suspend(selector)
            return .ok
        case .restart(let selector, let presentation):
            try await commands.restart(selector, presentation: presentation)
            return .ok
        case .open(let selector):
            try commands.open(selector)
            return .ok
        case .reveal(let selector):
            try commands.reveal(selector)
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

        case .editStorageDisk(let selector, let edit):
            try await apply(edit, to: selector)
            return .ok
        case .editRemovableMedia(let selector, let edit):
            try await apply(edit, to: selector)
            return .ok
        case .editSharedDirectory(let selector, let edit):
            try apply(edit, to: selector)
            return .ok
        case .guestAgentDisk(let selector, let edit):
            switch edit {
            case .mount: _ = try commands.mountGuestAgentDisk(selector)
            case .unmount: try commands.unmountGuestAgentDisk(selector)
            }
            return .ok
        }
    }

    /// One storage-disk edit, dispatched on the payload the verb carries.
    private func apply(_ edit: StorageDiskEdit, to selector: VMSelector) async throws {
        switch edit {
        case .create(let sizeInGB):
            try await commands.createStorageDisk(selector, sizeInGB: sizeInGB)
        case .remove(let disk, let trashFile, let confirmed):
            try await commands.removeStorageDisk(
                selector, disk: disk, trashFile: trashFile, confirmed: confirmed)
        case .rename(let disk, let newLabel):
            try commands.renameStorageDisk(selector, disk: disk, to: newLabel)
        case .setNotes(let disk, let notes):
            try commands.setStorageDiskNotes(selector, disk: disk, notes: notes)
        case .setReadOnly(let disk, let readOnly):
            try commands.setStorageDiskReadOnly(selector, disk: disk, readOnly: readOnly)
        case .reorder(let order):
            try commands.reorderStorageDisks(selector, order: order)
        }
    }

    /// One removable-media edit, dispatched on the payload the verb carries.
    private func apply(_ edit: RemovableMediaEdit, to selector: VMSelector) async throws {
        switch edit {
        case .remove(let item, let trashFile, let confirmed):
            try await commands.removeRemovableMedia(
                selector, item: item, trashFile: trashFile, confirmed: confirmed)
        case .eject(let item):
            try commands.ejectRemovableMedia(selector, item: item)
        case .rename(let item, let newLabel):
            try commands.renameRemovableMedia(selector, item: item, to: newLabel)
        case .setNotes(let item, let notes):
            try commands.setRemovableMediaNotes(selector, item: item, notes: notes)
        case .setReadOnly(let item, let readOnly):
            try commands.setRemovableMediaReadOnly(selector, item: item, readOnly: readOnly)
        }
    }

    /// One shared-directory edit, dispatched on the payload the verb carries.
    private func apply(_ edit: SharedDirectoryEdit, to selector: VMSelector) throws {
        switch edit {
        case .remove(let directory):
            try commands.removeSharedDirectory(selector, directory: directory)
        case .setReadOnly(let directory, let readOnly):
            try commands.setSharedDirectoryReadOnly(
                selector, directory: directory, readOnly: readOnly)
        }
    }

    // MARK: - Events

    /// Every library change as an encoded response, for a transport that
    /// streams them.
    func eventResponses() -> AsyncStream<VMCommandResponse> {
        let events = commands.events()
        return AsyncStream { continuation in
            let task = Task {
                for await batch in events {
                    for event in batch {
                        continuation.yield(VMCommandResponse(result: .event(event)))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
