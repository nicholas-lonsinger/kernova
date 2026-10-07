import Foundation

@testable import Kernova

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
/// from detached tasks. Recursive, because an access's body reads back through
/// the same store.
final class InMemoryVMBundleFiles: VMBundleFileAccessing, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var bundles: [URL: [String: Data]] = [:]
    private var replaceCounts: [String: Int] = [:]
    private var readCounts: [String: Int] = [:]
    private var replaceErrors: [String: any Error] = [:]
    private var unreadable: Set<BundlePath> = []
    private var target: InMemoryVMBundleFiles?
    private var lockedElsewhere: Set<URL> = []
    private var lockedByThisCopy: Set<URL> = []
    private var lockErrors: [URL: any Error] = [:]
    private let disk = CoordinatedBundleFileAccess()

    private struct BundlePath: Hashable {
        let bundle: URL
        let relativePath: String
    }

    private static func key(_ url: URL) -> URL { url.standardizedFileURL }

    // MARK: - Accounting

    /// How many replaces of `relativePath` landed, across every bundle.
    func replaceCount(of relativePath: String) -> Int {
        if let target { return target.replaceCount(of: relativePath) }
        return lock.withLock { replaceCounts[relativePath, default: 0] }
    }

    /// How many reads of `relativePath` an access made, across every bundle.
    func readCount(of relativePath: String) -> Int {
        if let target { return target.readCount(of: relativePath) }
        return lock.withLock { readCounts[relativePath, default: 0] }
    }

    /// Thrown by every later replace of `relativePath`, in every bundle; `nil`
    /// clears it.
    func setReplaceError(_ error: (any Error)?, for relativePath: String) {
        if let target { return target.setReplaceError(error, for: relativePath) }
        lock.withLock { replaceErrors[relativePath] = error }
    }

    func replaceError(for relativePath: String) -> (any Error)? {
        if let target { return target.replaceError(for: relativePath) }
        return lock.withLock { replaceErrors[relativePath] }
    }

    /// Makes `relativePath` in the bundle at `url` read as present but
    /// unreadable, or readable again.
    func setUnreadable(_ isUnreadable: Bool, relativePath: String, at url: URL) {
        if let target { return target.setUnreadable(isUnreadable, relativePath: relativePath, at: url) }
        let path = BundlePath(bundle: Self.key(url), relativePath: relativePath)
        lock.withLock {
            if isUnreadable { unreadable.insert(path) } else { unreadable.remove(path) }
        }
    }

    // MARK: - Raw files

    /// The bytes `relativePath` holds in the bundle at `url`, `nil` when absent.
    func data(atRelativePath relativePath: String, in url: URL) -> Data? {
        if let target { return target.data(atRelativePath: relativePath, in: url) }
        return lock.withLock { bundles[Self.key(url)]?[relativePath] }
    }

    /// Puts `data` at `relativePath` in the bundle at `url` as though it were
    /// already there, counting nothing; `nil` removes the file. Either way the
    /// store holds the bundle from then on, so it is no longer read on disk.
    func setData(_ data: Data?, atRelativePath relativePath: String, in url: URL) {
        if let target { return target.setData(data, atRelativePath: relativePath, in: url) }
        lock.withLock { bundles[Self.key(url), default: [:]][relativePath] = data }
    }

    /// Every bundle this store holds a file for.
    var bundleURLs: [URL] {
        if let target { return target.bundleURLs }
        return lock.withLock { Array(bundles.keys) }
    }

    func holds(_ url: URL) -> Bool {
        if let target { return target.holds(url) }
        return lock.withLock { bundles[Self.key(url)] != nil }
    }

    /// Re-keys everything held at `source` to `destination`, its run lock
    /// included, as a rename of the bundle directory would.
    /// Copies every file this store holds at or under each of `relativePaths`
    /// in the bundle at `source` to the same path in the bundle at
    /// `destination`, as a clone copies those paths on disk.
    func copyFiles(_ relativePaths: [String], from source: URL, to destination: URL) {
        if let target { return target.copyFiles(relativePaths, from: source, to: destination) }
        lock.withLock {
            guard let files = bundles[Self.key(source)] else { return }
            for (path, data) in files
            where relativePaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                bundles[Self.key(destination), default: [:]][path] = data
            }
        }
    }

    func moveBundle(from source: URL, to destination: URL) {
        if let target { return target.moveBundle(from: source, to: destination) }
        lock.withLock {
            if lockedByThisCopy.remove(Self.key(source)) != nil {
                lockedByThisCopy.insert(Self.key(destination))
                for (id, url) in holders where url == Self.key(source) {
                    holders[id] = Self.key(destination)
                }
            }
            if lockedElsewhere.remove(Self.key(source)) != nil {
                lockedElsewhere.insert(Self.key(destination))
            }
            guard let files = bundles.removeValue(forKey: Self.key(source)) else { return }
            bundles[Self.key(destination)] = files
        }
    }

    // MARK: - Run lock

    /// Marks the bundle at `url` as one another copy of Kernova holds: every
    /// lock attempt on it is refused until ``releaseElsewhere(_:)``.
    func holdElsewhere(_ url: URL) {
        if let target { return target.holdElsewhere(url) }
        lock.withLock { _ = lockedElsewhere.insert(Self.key(url)) }
    }

    /// Ends the hold ``holdElsewhere(_:)`` stood for.
    func releaseElsewhere(_ url: URL) {
        if let target { return target.releaseElsewhere(url) }
        lock.withLock { _ = lockedElsewhere.remove(Self.key(url)) }
    }

    /// Thrown by every later lock attempt on the bundle at `url`, as opening a
    /// directory that has gone would; `nil` clears it.
    func setLockError(_ error: (any Error)?, at url: URL) {
        if let target { return target.setLockError(error, at: url) }
        lock.withLock { lockErrors[Self.key(url)] = error }
    }

    /// Whether this copy holds the run lock on the bundle at `url` right now.
    func isLockedByThisCopy(_ url: URL) -> Bool {
        if let target { return target.isLockedByThisCopy(url) }
        return lock.withLock { lockedByThisCopy.contains(Self.key(url)) }
    }

    /// Every bundle this copy holds the run lock on right now.
    var bundlesLockedByThisCopy: Set<URL> {
        if let target { return target.bundlesLockedByThisCopy }
        return lock.withLock { lockedByThisCopy }
    }

    /// What holds one bundle's run lock, releasing it as it goes — under
    /// whatever URL a rename has carried it to since.
    private final class Holder: @unchecked Sendable {
        let store: InMemoryVMBundleFiles
        let id = UUID()

        init(store: InMemoryVMBundleFiles) {
            self.store = store
        }

        deinit {
            store.releaseHolder(id)
        }
    }

    /// Which bundle each live holder locks, re-keyed with its bundle.
    private var holders: [UUID: URL] = [:]

    fileprivate func releaseHolder(_ id: UUID) {
        lock.withLock {
            guard let url = holders.removeValue(forKey: id) else { return }
            lockedByThisCopy.remove(url)
        }
    }

    func removeBundle(at url: URL) {
        if let target { return target.removeBundle(at: url) }
        lock.withLock { _ = bundles.removeValue(forKey: Self.key(url)) }
    }

    /// Moves every bundle this store holds into `other` and forwards every
    /// later call there.
    func forward(to other: InMemoryVMBundleFiles) {
        guard other !== self else { return }
        lock.withLock {
            for (url, files) in bundles {
                for (path, data) in files { other.setData(data, atRelativePath: path, in: url) }
            }
            bundles.removeAll()
            target = other
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
        return try lock.withLock {
            if let error = lockErrors[key] { throw error }
            guard !lockedElsewhere.contains(key), lockedByThisCopy.insert(key).inserted else {
                return nil
            }
            let holder = Holder(store: self)
            holders[holder.id] = key
            return holder
        }
    }

    func isBundleLockedElsewhere(at bundleURL: URL) throws -> Bool {
        if let target { return try target.isBundleLockedElsewhere(at: bundleURL) }
        let key = Self.key(bundleURL)
        return lock.withLock { lockedElsewhere.contains(key) || lockedByThisCopy.contains(key) }
    }

    func reading<T>(_ bundleURL: URL, _ body: (any VMBundleFileReading) throws -> T) throws -> T {
        if let target { return try target.reading(bundleURL, body) }
        guard holds(bundleURL) else { return try disk.reading(bundleURL, body) }
        return try lock.withLock { try body(Handle(store: self, bundle: Self.key(bundleURL))) }
    }

    func writing<T>(
        _ bundleURL: URL, _ key: borrowing VMBundleFileWriteKey,
        _ body: (any VMBundleFileWriting) throws -> T
    ) throws -> T {
        if let target { return try target.writing(bundleURL, key, body) }
        guard holds(bundleURL) else { return try disk.writing(bundleURL, key, body) }
        return try lock.withLock { try body(Handle(store: self, bundle: Self.key(bundleURL))) }
    }

    private struct Handle: VMBundleFileWriting {
        let store: InMemoryVMBundleFiles
        let bundle: URL

        func data(atRelativePath relativePath: String) throws -> Data? {
            store.readCounts[relativePath, default: 0] += 1
            if store.unreadable.contains(BundlePath(bundle: bundle, relativePath: relativePath)) {
                throw CocoaError(.fileReadCorruptFile)
            }
            return store.bundles[bundle]?[relativePath]
        }

        func replace(atRelativePath relativePath: String, with data: Data) throws {
            if let error = store.replaceErrors[relativePath] { throw error }
            store.bundles[bundle, default: [:]][relativePath] = data
            store.replaceCounts[relativePath, default: 0] += 1
        }
    }
}
