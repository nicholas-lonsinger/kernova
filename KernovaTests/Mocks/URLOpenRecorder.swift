import Foundation

/// Records the URLs handed to a `SystemSettingsLink`, answering each attempt
/// with the next queued result (and `false` once the queue is spent).
@MainActor
final class URLOpenRecorder {
    private(set) var opened: [String] = []
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func open(_ url: URL) -> Bool {
        opened.append(url.absoluteString)
        return results.isEmpty ? false : results.removeFirst()
    }
}
