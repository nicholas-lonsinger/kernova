import Foundation

/// Minimal `FileManager` surface for the destructive file operations —
/// trashing and permanent removal — plus the existence probe that gates them.
///
/// This is a test seam, not a general `FileManager` façade: read-only calls
/// (`contentsOfDirectory`, `copyItem`, …) stay on `FileManager.default` at
/// their call sites. Trash calls must go through this seam because a unit
/// test exercising the real thing deposits its fixture files in the user's
/// actual ~/.Trash on every run; `removeItem` rides along as trash's
/// "Delete Immediately" twin so a mock observes both dispositions of the
/// same delete flow. `Sendable` because trashing runs in `Task.detached`
/// (it can block for seconds on slow volumes), so the injected value
/// crosses isolation domains.
protocol FileSystemOperating: Sendable {
    func fileExists(atPath path: String) -> Bool
    func trashItem(at url: URL) throws
    func removeItem(at url: URL) throws
}

extension FileManager: FileSystemOperating {
    func trashItem(at url: URL) throws {
        try trashItem(at: url, resultingItemURL: nil)
    }
}
