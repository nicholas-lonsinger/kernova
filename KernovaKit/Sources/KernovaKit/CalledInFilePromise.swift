import Foundation
import KernovaSynchronization

/// A file promise called in: its receiver, and each file its source names once called in, landing in the
/// folder it was called into.
@MainActor
public struct CalledInFilePromise {
    /// One file the promise lands.
    public struct File: Sendable {
        /// The name its source gave it; empty when the source named nothing.
        public let name: String
        /// The file its source writes for it, or why it wrote none. Its source sets no deadline, so neither
        /// does this.
        public let landed: Task<URL, any Error>
    }

    /// The promise.
    public let receiver: any FilePromiseReceiving
    /// One per name the receiver gives once called in, in its order, or a single unnamed one when it gives
    /// none.
    public let files: [File]

    /// Calls `receiver` in now, its files landing in `folder` and its source's reports arriving on
    /// `operationQueue`, which a drop's call-ins may share.
    ///
    /// A source reports each file it writes, or fails, once. A report goes to the file of the name it lands
    /// under, or else to the first file still owed one; a report beyond the files named is not one of them.
    public static func callIn(
        _ receiver: any FilePromiseReceiving, into folder: URL, operationQueue: OperationQueue = OperationQueue()
    ) -> CalledInFilePromise {
        let reports = Reports()
        receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: operationQueue) {
            url, error in
            reports.record(url, error.map { .failure($0) } ?? .success(url))
        }
        let named = receiver.fileNames.filter { !$0.isEmpty }
        let names = named.isEmpty ? [""] : named
        reports.name(names)
        return CalledInFilePromise(
            receiver: receiver,
            files: names.indices.map { index in
                File(name: names[index], landed: Task { try await reports.value(index) })
            })
    }

    /// What a call-in's source reports, matched to the files its receiver names, whether a report comes before
    /// or after the names are read, and before or after the file is awaited.
    private final class Reports: Sendable {
        private struct State {
            var names: [String]?
            var early: [(url: URL, result: Result<URL, any Error>)] = []
            var results: [Result<URL, any Error>?] = []
            var waiters: [Int: CheckedContinuation<URL, any Error>] = [:]
        }

        private let state = Locked(State())

        func record(_ url: URL, _ result: Result<URL, any Error>) {
            let resumed = state.withLock { state -> (CheckedContinuation<URL, any Error>, Result<URL, any Error>)? in
                guard state.names != nil else {
                    state.early.append((url, result))
                    return nil
                }
                return Self.assign(url, result, &state)
            }
            if let (waiter, result) = resumed { waiter.resume(with: result) }
        }

        func name(_ names: [String]) {
            state.withLock { state in
                state.names = names
                state.results = Array(repeating: nil, count: names.count)
                for report in state.early { _ = Self.assign(report.url, report.result, &state) }
                state.early = []
            }
        }

        func value(_ index: Int) async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<URL, any Error>? in
                    if state.results[index] == nil { state.waiters[index] = continuation }
                    return state.results[index]
                }
                if let result { continuation.resume(with: result) }
            }
        }

        /// Settles the file `url` reports on, returning its waiter to resume.
        private static func assign(_ url: URL, _ result: Result<URL, any Error>, _ state: inout State)
            -> (CheckedContinuation<URL, any Error>, Result<URL, any Error>)?
        {
            guard let names = state.names else { return nil }
            let owed = names.indices.filter { state.results[$0] == nil }
            guard let index = owed.first(where: { names[$0] == url.lastPathComponent }) ?? owed.first else {
                return nil
            }
            state.results[index] = result
            return state.waiters.removeValue(forKey: index).map { ($0, result) }
        }
    }
}
