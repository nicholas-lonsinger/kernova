import Foundation

/// A library file every copy of Kernova sharing the library reads and
/// changes, each access under `NSFileCoordinator`.
///
/// ``update(_:)`` applies a change to what the file holds at that moment, so
/// a change another copy made since this one last read is changed rather than
/// overwritten, and a file that cannot be read is never written.
struct CoordinatedJSONFile<Payload: Codable & Equatable & Sendable>: Sendable {
    /// Why a read or a change did not complete.
    enum Failure: Error {
        /// The file exists and could not be read; a change writes nothing.
        case unreadable(any Error)
        /// The change could not be written.
        case unsaved(any Error)

        /// Why, in the words the user reads.
        var reason: String {
            switch self {
            case .unreadable(let underlying), .unsaved(let underlying): underlying.localizedDescription
            }
        }
    }

    let url: URL
    /// What the file holds before anything writes it.
    let empty: Payload

    /// What the file holds now.
    func read() throws(Failure) -> Payload {
        var coordinationError: NSError?
        var outcome: Result<Payload, any Error> = .success(empty)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinated in
            outcome = Result { try decode(coordinated) }
        }
        if let coordinationError { throw .unreadable(coordinationError) }
        do {
            return try outcome.get()
        } catch {
            throw .unreadable(error)
        }
    }

    /// Writes `change` applied to what the file holds now, under one
    /// coordinated write, and answers what it wrote. An error `change` throws
    /// passes through as it is, with nothing written; a change that leaves
    /// the payload as it was writes nothing either.
    func update(_ change: (Payload) throws -> Payload) throws -> Payload {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var outcome: Result<Payload, any Error> = .success(empty)
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forMerging, error: &coordinationError
        ) { coordinated in
            outcome = Result {
                let current: Payload
                do {
                    current = try decode(coordinated)
                } catch {
                    throw Failure.unreadable(error)
                }
                let candidate = try change(current)
                guard candidate != current else { return current }
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(candidate).write(to: coordinated, options: .atomic)
                } catch {
                    throw Failure.unsaved(error)
                }
                return candidate
            }
        }
        if let coordinationError { throw Failure.unsaved(coordinationError) }
        return try outcome.get()
    }

    /// What the file at `url` holds, ``empty`` when there is no file.
    private func decode(_ url: URL) throws -> Payload {
        do {
            return try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return empty
        }
    }
}
