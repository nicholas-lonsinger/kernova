import Foundation
import KernovaLogging

/// The unreadable config files already put in front of the user, so the
/// check comes up once for each newly unreadable file.
struct UnreadableFileReports {
    /// Each reported file, by ``VMBundleIdentity/nameKey(_:)``.
    private var reported: Set<String> = []

    /// Takes `found` as every unreadable file a read of `scope` — a bundle,
    /// or one library file — just met, answering whether any is newly
    /// unreadable. A file under `scope` that `found` leaves out reads again
    /// and is forgotten, so a later failure of it is new again.
    mutating func record(_ found: [UnreadableConfigFile], under scope: URL) -> Bool {
        let scopeKey = VMBundleIdentity.nameKey(scope)
        let found = Set(found.map { VMBundleIdentity.nameKey($0.url) })
        let isNew = !found.isSubset(of: reported)
        reported = reported.filter { $0 != scopeKey && !$0.hasPrefix(scopeKey + "/") }.union(found)
        return isNew
    }

    /// Forgets every file under none of `scopes` — what is no longer on disk.
    mutating func forgetAll(outside scopes: [URL]) {
        let keys = scopes.map(VMBundleIdentity.nameKey)
        reported = reported.filter { key in keys.contains { key == $0 || key.hasPrefix($0 + "/") } }
    }
}

/// The config check: every config file in the library read fresh from disk,
/// the defaults put in place in the ones that have one for every problem, and
/// the whole of a bundle no read can take moved to the Trash.
extension VMLibrary {
    /// Records `found` as what a read of `scope` met
    /// (``UnreadableFileReports/record(_:under:)``), owing the check when any
    /// of it is newly unreadable.
    func recordUnreadable(_ found: [UnreadableConfigFile], under scope: URL) {
        if unreadableReports.record(found, under: scope) { owesUnreadableReport = true }
    }

    /// Asks for the check once for everything newly unreadable since the
    /// last ask.
    func reportNewlyUnreadable() {
        guard owesUnreadableReport else { return }
        owesUnreadableReport = false
        onUnreadableFilesFound?()
    }

    /// Every config file in the library that a read refuses — each VM's state
    /// files, the `config.json` of each snapshot its manifest lists,
    /// `Networks.json` and `Organization.json` — read fresh from disk, through
    /// the decode the library's own reads take.
    func checkConfigFiles() async throws -> [UnreadableConfigFile] {
        let storage = storageService
        let networksFile = networks.file
        let organizationFile = organization.file
        return try await Task.detached(priority: .userInitiated) {
            try Self.unreadableConfigFiles(
                storage: storage, networksFile: networksFile, organizationFile: organizationFile)
        }.value
    }

    /// ``checkConfigFiles()``'s read, in ``bundleNameOrder(_:_:)`` and then the
    /// library's own files.
    nonisolated static func unreadableConfigFiles(
        storage: any VMStorageProviding,
        networksFile: CoordinatedJSONFile<VMNetworkDirectory.File>?,
        organizationFile: CoordinatedJSONFile<VMOrganizationDirectory.File>?
    ) throws -> [UnreadableConfigFile] {
        var found = try storage.listVMBundles().sorted(by: bundleNameOrder).flatMap {
            VMBundleFiles(url: $0, access: storage.bundleFiles).unreadableFiles()
        }
        func attempt<Payload>(_ file: CoordinatedJSONFile<Payload>?) {
            do throws(UnreadableConfigFile) {
                _ = try file?.read()
            } catch {
                found.append(error)
            }
        }
        attempt(networksFile)
        attempt(organizationFile)
        return found
    }

    /// One file Use Defaults left as it was, and why.
    struct ConfigFileRepairFailure: Sendable {
        let file: UnreadableConfigFile
        let reason: String
    }

    /// Puts the defaults in place in every repairable file of `files`,
    /// through each file's own write path, then reads the network list and
    /// the VMs directory again — answering the files it left as they were.
    ///
    /// What each file holds is decided again as it is written, so a file
    /// another process changed since the check is never written from the
    /// check's view of it.
    func useDefaults(in files: [UnreadableConfigFile]) async -> [ConfigFileRepairFailure] {
        let storage = storageService
        let fileSystem = lifecycle.fileSystem
        let repairable = files.filter(\.isRepairable)
        let failures = await Task.detached(priority: .userInitiated) {
            repairable.compactMap { file -> ConfigFileRepairFailure? in
                do {
                    switch file.location {
                    case .bundle(let bundleURL, let id):
                        _ = try VMBundleFiles(url: bundleURL, access: storage.bundleFiles)
                            .repair(id, as: file, trashingOriginalWith: fileSystem)
                    case .networkList(let url):
                        _ = try VMNetworkDirectory.file(at: url).repair(file, trashingOriginalWith: fileSystem)
                    case .organization(let url):
                        _ = try VMOrganizationDirectory.file(at: url)
                            .repair(file, trashingOriginalWith: fileSystem)
                    }
                    return nil
                } catch {
                    return ConfigFileRepairFailure(file: file, reason: error.localizedDescription)
                }
            }
        }.value
        for failure in failures {
            #log(
                Self.logger, .error,
                "Use Defaults left \(failure.file.url.path(percentEncoded: false), privacy: .public) as it was: \(failure.reason, privacy: .public)"
            )
        }
        #log(
            Self.logger, .notice,
            "Use Defaults rewrote \(repairable.count - failures.count, privacy: .public) of \(repairable.count, privacy: .public) repairable config file(s)"
        )
        reconcileWithDisk()
        return failures
    }

    /// Moves the bundle `bundle` was read from to the Trash, everything in it
    /// included, and reads the VMs directory again.
    ///
    /// Holds the bundle's run lock across the move, as every delete does, so
    /// it refuses with ``ConfigFileRepairRefusal/inUse`` while any copy of
    /// Kernova holds it.
    func moveToTrash(_ bundle: UnreadableVM) async throws {
        let storage = storageService
        let url = bundle.bundleURL
        try await Task.detached(priority: .userInitiated) {
            guard let lock = try VMBundleFiles(url: url, access: storage.bundleFiles).lockRun() else {
                throw ConfigFileRepairRefusal.inUse
            }
            try withExtendedLifetime(lock) {
                try storage.deleteVMBundle(at: url)
            }
        }.value
        #log(
            Self.logger, .notice,
            "Moved the unreadable bundle \(url.lastPathComponent, privacy: .public) to the Trash")
        reconcileWithDisk()
    }
}
