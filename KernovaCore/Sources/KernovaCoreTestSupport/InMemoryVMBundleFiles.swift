import Foundation
import Synchronization

@testable import KernovaCore

/// `VMBundleFileAccessing` over an in-memory file map per bundle URL, with
/// read and replace counts and injected failures per bundle-relative path.
///
/// A bundle it holds nothing for is read and written on disk through
/// ``CoordinatedBundleFileAccess``, so a bundle a test really copies — an
/// import's — behaves as it does in production.
///
/// ``forward(to:)`` hands every bundle this store holds to another store and
/// makes this one a pass-through to it: how a fixture VM built over its own
/// store is registered with a library whose storage owns another.
///
/// Every bundle's run lock is held in memory, keyed by the bundle URL and
/// re-keyed by ``moveBundle(from:to:)`` as a rename carries the real one;
/// ``holdElsewhere(_:)`` stands in for another copy of Kernova holding it.
///
/// Lock-based because the protocol is `Sendable` and the library reads bundles
/// from detached tasks.
final class InMemoryVMBundleFiles: VMBundleFileAccessing {
    private struct BundlePath: Hashable {
        let bundle: URL
        let relativePath: String
    }

    private struct State {
        var bundles: [URL: [String: Data]] = [:]
        var replaceCounts: [String: Int] = [:]
        var readCounts: [String: Int] = [:]
        var replaceErrors: [String: any Error] = [:]
        var unreadable: Set<BundlePath> = []
        var target: InMemoryVMBundleFiles?
        var lockedElsewhere: Set<URL> = []
        var lockedElsewhereUnprobed: Set<URL> = []
        var lockedByThisCopy: Set<URL> = []
        var lockErrors: [URL: any Error] = [:]
        /// Which bundle each live holder locks, re-keyed with its bundle.
        var holders: [UUID: URL] = [:]

        mutating func read(_ relativePath: String, in bundle: URL) throws -> Data? {
            readCounts[relativePath, default: 0] += 1
            if unreadable.contains(BundlePath(bundle: bundle, relativePath: relativePath)) {
                throw CocoaError(.fileReadCorruptFile)
            }
            return bundles[bundle]?[relativePath]
        }

        mutating func replace(_ relativePath: String, in bundle: URL, with data: Data) throws {
            if let error = replaceErrors[relativePath] { throw error }
            bundles[bundle, default: [:]][relativePath] = data
            replaceCounts[relativePath, default: 0] += 1
        }
    }

    private let state = Mutex(State())
    /// Held across each `reading` or `writing` body, so no access sees another
    /// part-way.
    private let access = NSLock()
    private let disk = CoordinatedBundleFileAccess()

    private static func key(_ url: URL) -> URL { url.standardizedFileURL }

    /// The store every call forwards to once ``forward(to:)`` has run.
    private var target: InMemoryVMBundleFiles? { state.withLock { $0.target } }

    // MARK: - Accounting

    /// How many replaces of `relativePath` landed, across every bundle.
    func replaceCount(of relativePath: String) -> Int {
        if let target { return target.replaceCount(of: relativePath) }
        return state.withLock { $0.replaceCounts[relativePath, default: 0] }
    }

    /// How many reads of `relativePath` an access made, across every bundle.
    func readCount(of relativePath: String) -> Int {
        if let target { return target.readCount(of: relativePath) }
        return state.withLock { $0.readCounts[relativePath, default: 0] }
    }

    /// Thrown by every later replace of `relativePath`, in every bundle; `nil`
    /// clears it.
    func setReplaceError(_ error: (any Error)?, for relativePath: String) {
        if let target { return target.setReplaceError(error, for: relativePath) }
        state.withLock { $0.replaceErrors[relativePath] = error }
    }

    func replaceError(for relativePath: String) -> (any Error)? {
        if let target { return target.replaceError(for: relativePath) }
        return state.withLock { $0.replaceErrors[relativePath] }
    }

    /// Makes `relativePath` in the bundle at `url` read as present but
    /// unreadable, or readable again.
    func setUnreadable(_ isUnreadable: Bool, relativePath: String, at url: URL) {
        if let target { return target.setUnreadable(isUnreadable, relativePath: relativePath, at: url) }
        let path = BundlePath(bundle: Self.key(url), relativePath: relativePath)
        state.withLock {
            if isUnreadable { $0.unreadable.insert(path) } else { $0.unreadable.remove(path) }
        }
    }

    // MARK: - Raw files

    /// The bytes `relativePath` holds in the bundle at `url`, `nil` when absent.
    func data(atRelativePath relativePath: String, in url: URL) -> Data? {
        if let target { return target.data(atRelativePath: relativePath, in: url) }
        return state.withLock { $0.bundles[Self.key(url)]?[relativePath] }
    }

    /// Puts `data` at `relativePath` in the bundle at `url` as though it were
    /// already there, counting nothing; `nil` removes the file. Either way the
    /// store holds the bundle from then on, so it is no longer read on disk.
    func setData(_ data: Data?, atRelativePath relativePath: String, in url: URL) {
        if let target { return target.setData(data, atRelativePath: relativePath, in: url) }
        state.withLock { $0.bundles[Self.key(url), default: [:]][relativePath] = data }
    }

    /// Every bundle this store holds a file for.
    var bundleURLs: [URL] {
        if let target { return target.bundleURLs }
        return state.withLock { Array($0.bundles.keys) }
    }

    /// A new store holding a copy of every file this one holds, taken in one
    /// hold, so reads from it never see a seed or a write part-way.
    func snapshot() -> InMemoryVMBundleFiles {
        if let target { return target.snapshot() }
        let bundles = state.withLock { $0.bundles }
        let copy = InMemoryVMBundleFiles()
        copy.state.withLock { $0.bundles = bundles }
        return copy
    }

    func holds(_ url: URL) -> Bool {
        if let target { return target.holds(url) }
        return state.withLock { $0.bundles[Self.key(url)] != nil }
    }

    /// Copies every file this store holds at or under each of `relativePaths`
    /// in the bundle at `source` to the same path in the bundle at
    /// `destination`, as a clone copies those paths on disk.
    func copyFiles(_ relativePaths: [String], from source: URL, to destination: URL) {
        if let target { return target.copyFiles(relativePaths, from: source, to: destination) }
        state.withLock { state in
            guard let files = state.bundles[Self.key(source)] else { return }
            for (path, data) in files
            where relativePaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                state.bundles[Self.key(destination), default: [:]][path] = data
            }
        }
    }

    /// Re-keys everything held at `source` to `destination`, its run lock
    /// included, as a rename of the bundle directory would.
    func moveBundle(from source: URL, to destination: URL) {
        if let target { return target.moveBundle(from: source, to: destination) }
        state.withLock {
            if $0.lockedByThisCopy.remove(Self.key(source)) != nil {
                $0.lockedByThisCopy.insert(Self.key(destination))
                for (id, url) in $0.holders where url == Self.key(source) {
                    $0.holders[id] = Self.key(destination)
                }
            }
            if $0.lockedElsewhere.remove(Self.key(source)) != nil {
                $0.lockedElsewhere.insert(Self.key(destination))
            }
            guard let files = $0.bundles.removeValue(forKey: Self.key(source)) else { return }
            $0.bundles[Self.key(destination)] = files
        }
    }

    // MARK: - Run lock

    /// Marks the bundle at `url` as one another copy of Kernova holds: every
    /// lock attempt on it is refused until ``releaseElsewhere(_:)``.
    func holdElsewhere(_ url: URL) {
        if let target { return target.holdElsewhere(url) }
        state.withLock { _ = $0.lockedElsewhere.insert(Self.key(url)) }
    }

    /// Marks the bundle at `url` as one another copy of Kernova takes after
    /// this copy's last probe: probes read it free, and the next lock attempt
    /// finds it held — from then on as ``holdElsewhere(_:)`` holds it.
    func holdElsewhereAfterProbes(_ url: URL) {
        if let target { return target.holdElsewhereAfterProbes(url) }
        state.withLock { _ = $0.lockedElsewhereUnprobed.insert(Self.key(url)) }
    }

    /// Ends the hold ``holdElsewhere(_:)`` or
    /// ``holdElsewhereAfterProbes(_:)`` stood for.
    func releaseElsewhere(_ url: URL) {
        if let target { return target.releaseElsewhere(url) }
        state.withLock {
            _ = $0.lockedElsewhere.remove(Self.key(url))
            _ = $0.lockedElsewhereUnprobed.remove(Self.key(url))
        }
    }

    /// Thrown by every later lock attempt on the bundle at `url`, as opening a
    /// directory that has gone would; `nil` clears it.
    func setLockError(_ error: (any Error)?, at url: URL) {
        if let target { return target.setLockError(error, at: url) }
        state.withLock { $0.lockErrors[Self.key(url)] = error }
    }

    /// Whether this copy holds the run lock on the bundle at `url` right now.
    func isLockedByThisCopy(_ url: URL) -> Bool {
        if let target { return target.isLockedByThisCopy(url) }
        return state.withLock { $0.lockedByThisCopy.contains(Self.key(url)) }
    }

    /// Every bundle this copy holds the run lock on right now.
    var bundlesLockedByThisCopy: Set<URL> {
        if let target { return target.bundlesLockedByThisCopy }
        return state.withLock { $0.lockedByThisCopy }
    }

    /// What holds one bundle's run lock, releasing it as it goes — under
    /// whatever URL a rename has carried it to since.
    private final class Holder: Sendable {
        let store: InMemoryVMBundleFiles
        let id: UUID

        init(store: InMemoryVMBundleFiles, id: UUID) {
            self.store = store
            self.id = id
        }

        deinit {
            store.releaseHolder(id)
        }
    }

    fileprivate func releaseHolder(_ id: UUID) {
        state.withLock {
            guard let url = $0.holders.removeValue(forKey: id) else { return }
            $0.lockedByThisCopy.remove(url)
        }
    }

    func removeBundle(at url: URL) {
        if let target { return target.removeBundle(at: url) }
        state.withLock { _ = $0.bundles.removeValue(forKey: Self.key(url)) }
    }

    /// Moves every bundle this store holds into `other` and forwards every
    /// later call there.
    func forward(to other: InMemoryVMBundleFiles) {
        guard other !== self else { return }
        state.withLock { state in
            for (url, files) in state.bundles {
                for (path, data) in files { other.setData(data, atRelativePath: path, in: url) }
            }
            state.bundles.removeAll()
            state.target = other
        }
    }

    // MARK: - Typed seeding

    /// Seeds the bundle at `url` with the four state files, as though a
    /// bundle already held them; `nil` leaves a sidecar absent. Seeding a
    /// manifest also seeds each snapshot's `config.json` stub carrying its
    /// MAC address, which is where the manifest's decode reads it from.
    func seed(
        _ configuration: VMConfiguration, hostState: VMHostState? = nil,
        snapshots: VMSnapshotManifest? = nil, pairings: USBAccessoryPairingSet? = nil,
        at url: URL
    ) {
        setConfiguration(configuration, at: url)
        if let hostState { setHostState(hostState, at: url) }
        if let snapshots { setManifest(snapshots, at: url) }
        if let pairings { setPairings(pairings, at: url) }
    }

    func setConfiguration(_ configuration: VMConfiguration, at url: URL) {
        setData(Self.encode(configuration), atRelativePath: VMBundleLayout.configRelativePath, in: url)
    }

    func setHostState(_ hostState: VMHostState, at url: URL) {
        setData(Self.encode(hostState), atRelativePath: VMBundleLayout.hostStateRelativePath, in: url)
    }

    func setPairings(_ pairings: USBAccessoryPairingSet, at url: URL) {
        setData(Self.encode(pairings), atRelativePath: VMBundleLayout.usbPairingsRelativePath, in: url)
    }

    func setManifest(_ manifest: VMSnapshotManifest, at url: URL) {
        setData(
            Self.encode(manifest.record), atRelativePath: VMBundleLayout.snapshotManifestRelativePath,
            in: url)
        // Each snapshot's own `config.json` carries the network device the
        // manifest's reader takes from it.
        for snapshot in manifest.snapshots {
            guard let network = snapshot.network else { continue }
            setData(
                Self.encode(network),
                atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: snapshot.id), in: url)
        }
    }

    /// Writes snapshot `id`'s own `config.json` into a bundle this store holds,
    /// as a capture's preparation does; a bundle it does not hold is left
    /// alone.
    func setSnapshotConfiguration(_ configuration: VMConfiguration, id: UUID, at url: URL) {
        guard holds(url) else { return }
        setData(
            Self.encode(configuration),
            atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: id), in: url)
    }

    // MARK: - Typed reads

    func configuration(at url: URL) -> VMConfiguration? {
        guard holds(url) else { return nil }
        return try? VMBundleFiles(url: url, access: self).readConfiguration()
    }

    /// What the bundle's four files hold, read the way the library reads them;
    /// `nil` when the store holds no readable bundle there.
    func read(at url: URL) -> VMBundleRead? {
        guard holds(url) else { return nil }
        return try? VMBundleFiles(url: url, access: self).read()
    }

    func hostState(at url: URL) -> VMHostState? { read(at: url)?.hostState }
    func manifest(at url: URL) -> VMSnapshotManifest? { read(at: url)?.snapshotManifest }
    func pairings(at url: URL) -> USBAccessoryPairingSet? { read(at: url)?.usbPairings }

    private static func encode<Value: Encodable>(_ value: Value) -> Data {
        do {
            return try VMConfiguration.makeJSONEncoder().encode(value)
        } catch {
            preconditionFailure("A test seed could not be encoded: \(error)")
        }
    }

    // MARK: - VMBundleFileAccessing

    func lockBundle(at bundleURL: URL) throws -> (any VMBundleLockHolder)? {
        if let target { return try target.lockBundle(at: bundleURL) }
        let key = Self.key(bundleURL)
        let id: UUID? = try state.withLock { state in
            if let error = state.lockErrors[key] { throw error }
            if state.lockedElsewhereUnprobed.remove(key) != nil { state.lockedElsewhere.insert(key) }
            guard !state.lockedElsewhere.contains(key), state.lockedByThisCopy.insert(key).inserted
            else { return nil }
            let id = UUID()
            state.holders[id] = key
            return id
        }
        return id.map { Holder(store: self, id: $0) }
    }

    func isBundleLockedElsewhere(at bundleURL: URL) throws -> Bool {
        if let target { return try target.isBundleLockedElsewhere(at: bundleURL) }
        let key = Self.key(bundleURL)
        return state.withLock { $0.lockedElsewhere.contains(key) || $0.lockedByThisCopy.contains(key) }
    }

    func reading<T>(_ bundleURL: URL, _ body: (any VMBundleFileReading) throws -> T) throws -> T {
        if let target { return try target.reading(bundleURL, body) }
        guard holds(bundleURL) else { return try disk.reading(bundleURL, body) }
        return try access.withLock { try body(Handle(store: self, bundle: Self.key(bundleURL))) }
    }

    func writing<T>(
        _ bundleURL: URL, _ key: borrowing VMBundleFileWriteKey,
        _ body: (any VMBundleFileWriting) throws -> T
    ) throws -> T {
        if let target { return try target.writing(bundleURL, key, body) }
        guard holds(bundleURL) else { return try disk.writing(bundleURL, key, body) }
        return try access.withLock { try body(Handle(store: self, bundle: Self.key(bundleURL))) }
    }

    private struct Handle: VMBundleFileWriting {
        let store: InMemoryVMBundleFiles
        let bundle: URL

        func data(atRelativePath relativePath: String) throws -> Data? {
            try store.state.withLock { try $0.read(relativePath, in: bundle) }
        }

        func replace(atRelativePath relativePath: String, with data: Data) throws {
            try store.state.withLock { try $0.replace(relativePath, in: bundle, with: data) }
        }
    }
}
