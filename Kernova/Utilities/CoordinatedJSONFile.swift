import Foundation

/// A library file every copy of Kernova sharing the library reads and
/// changes, each access under `NSFileCoordinator`.
///
/// ``update(_:)`` applies a change to what the file holds at that moment, so
/// a change another copy made since this one last read is changed rather than
/// overwritten, and a file that cannot be read is never written. A file that
/// cannot be read throws ``UnreadableConfigFile``, so the config check lists
/// it and ``repair(trashingOriginalWith:)`` puts its defaults in place.
struct CoordinatedJSONFile<Payload: Codable & Equatable & Sendable>: Sendable {
    /// Why a change did not complete.
    enum Failure: Error {
        /// The file exists and could not be read; a change writes nothing.
        case unreadable(UnreadableConfigFile)
        /// The change could not be written.
        case unsaved(any Error)

        /// Why, in the words the user reads.
        var reason: String {
            switch self {
            case .unreadable(let file): file.errorDescription ?? file.summary
            case .unsaved(let underlying): underlying.localizedDescription
            }
        }
    }

    /// Where the file is, as the config check names it.
    let location: UnreadableConfigFile.Location
    /// Whose settings it holds, as the config check names it.
    let owner: UnreadableConfigFile.Owner
    /// What the file holds before anything writes it.
    let empty: Payload

    var url: URL { location.url }

    /// What the file holds now.
    func read() throws(UnreadableConfigFile) -> Payload {
        var coordinationError: NSError?
        var outcome: Result<Payload, UnreadableConfigFile> = .success(empty)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinated in
            do throws(UnreadableConfigFile) {
                outcome = .success(try decode(coordinated))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw unreadable(.fileUnreadable(reason: coordinationError.localizedDescription)) }
        return try outcome.get()
    }

    /// Writes `change` applied to what the file holds now, under one
    /// coordinated write, and answers what it wrote. An error `change` throws
    /// passes through as it is, with nothing written; a change that leaves
    /// the payload as it was writes nothing either. Every other failure
    /// throws ``Failure``.
    func update(_ change: (Payload) throws -> Payload) throws -> Payload {
        let outcome = try coordinatedWrite { coordinated in
            Result {
                let current: Payload
                do throws(UnreadableConfigFile) {
                    current = try decode(coordinated)
                } catch {
                    throw Failure.unreadable(error)
                }
                let candidate = try change(current)
                guard candidate != current else { return current }
                do {
                    try Self.makeEncoder().encode(candidate).write(to: coordinated, options: .atomic)
                } catch {
                    throw Failure.unsaved(error)
                }
                return candidate
            }
        }
        return try outcome.get()
    }

    /// Makes each repair `checked` lists in the file, moving what it held to
    /// the Trash first — the check's Use Defaults.
    ///
    /// Decides on what the file holds inside the coordinated write
    /// (``ConfigFileRepair/replacement(for:current:reads:diagnose:)``), and
    /// writes it atomically after the copy of what it held is in the Trash,
    /// so the file is never absent or half-written.
    func repair(
        _ checked: UnreadableConfigFile, trashingOriginalWith fileSystem: any FileSystemOperating
    ) throws -> ConfigFileRepair {
        try coordinatedWrite { coordinated in
            Result { () throws -> ConfigFileRepair in
                let current: Data?
                do {
                    current = try Data(contentsOf: coordinated)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    current = nil
                }
                // No file reads as the empty payload.
                guard
                    let replacement = try ConfigFileRepair.replacement(
                        for: checked, current: current,
                        reads: { data in data.map { (try? decode($0)) != nil } ?? true }, diagnose: diagnose)
                else { return .alreadyReadable }
                try ConfigFileRepair.moveOriginalToTrash(
                    replacement.original, named: checked.trashedOriginalName, using: fileSystem)
                try replacement.repaired.write(to: coordinated, options: .atomic)
                return .repaired
            }
        }.get()
    }

    /// What the file at `url` holds, ``empty`` when there is no file.
    private func decode(_ url: URL) throws(UnreadableConfigFile) -> Payload {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return empty
        } catch {
            throw unreadable(.fileUnreadable(reason: error.localizedDescription))
        }
        return try decode(data)
    }

    /// The payload `data` decodes to; a refusal decodes the bytes again to
    /// say why.
    private func decode(_ data: Data) throws(UnreadableConfigFile) -> Payload {
        do {
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UnreadableConfigFile(
                location: location, owner: owner, fallbackName: url.lastPathComponent,
                diagnosis: diagnose(data), strictFailure: error)
        }
    }

    private func diagnose(_ data: Data) -> ConfigFileDiagnosis {
        ConfigFileDiagnosis(
            decoding: Payload.self, from: data, decoder: JSONDecoder(), encoder: Self.makeEncoder())
    }

    private func unreadable(_ issue: ConfigProblem.Issue) -> UnreadableConfigFile {
        UnreadableConfigFile(
            location: location, owner: owner, problems: [ConfigProblem(path: nil, issue: issue)])
    }

    /// `body` under a coordinated write of the file, creating the folder it
    /// sits in first; a write that cannot be coordinated throws
    /// ``Failure/unsaved(_:)``.
    private func coordinatedWrite<T>(_ body: (URL) -> T) throws(Failure) -> T {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var outcome: T?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forMerging, error: &coordinationError
        ) { coordinated in
            outcome = body(coordinated)
        }
        if let coordinationError { throw .unsaved(coordinationError) }
        guard let outcome else {
            preconditionFailure("A coordinated write that reported no error ran nothing")
        }
        return outcome
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
