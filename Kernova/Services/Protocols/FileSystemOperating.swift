import Foundation

/// Minimal `FileManager` surface for the destructive file operations —
/// trashing and permanent removal — plus the existence probe that gates them.
///
/// Trash calls must go through this seam: a unit test exercising the real
/// `FileManager` deposits its fixture files in the user's actual ~/.Trash on
/// every run. Read-only calls (`contentsOfDirectory`, `copyItem`, …) stay on
/// `FileManager.default` at their call sites. `Sendable` because trashing runs
/// in `Task.detached`, so the injected value crosses isolation domains.
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
