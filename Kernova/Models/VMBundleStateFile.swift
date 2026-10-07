import Foundation

/// Which of a bundle's state files one is, by the write path that repairs it.
enum VMBundleStateFileID: Sendable, Hashable {
    case configuration
    case hostState
    case snapshotManifest
    case usbPairings
    /// The `config.json` the snapshot with this identifier was taken under.
    case snapshotConfiguration(UUID)

    var relativePath: String {
        switch self {
        case .configuration: VMBundleLayout.configRelativePath
        case .hostState: VMBundleLayout.hostStateRelativePath
        case .snapshotManifest: VMBundleLayout.snapshotManifestRelativePath
        case .usbPairings: VMBundleLayout.usbPairingsRelativePath
        case .snapshotConfiguration(let id): VMBundleLayout.snapshotConfigRelativePath(id: id)
        }
    }
}

/// A state file a VM bundle holds, which only ``VMBundleFiles`` reads and
/// replaces: where it lives in the bundle and how its bytes map to a value.
///
/// Absence reads as the default for every file but a `config.json`, whose
/// absence means there is no configuration to read. A file that is present
/// but cannot be read or decoded throws ``UnreadableConfigFile``, so nothing
/// can mistake it for the default a later write would put over it.
struct VMBundleStateFile<Value: Equatable & Sendable>: Sendable {
    let id: VMBundleStateFileID
    /// Decodes the file's bytes, `nil` when the bundle holds no such file.
    /// `files` is the same coordinated access, for a value assembled from
    /// more than one file.
    private let decode: @Sendable (_ data: Data?, _ files: any VMBundleFileReading) throws -> Value
    fileprivate let encode: @Sendable (Value) throws -> Data
    /// Decodes bytes the strict decode refused again, recording every problem.
    fileprivate let diagnose: @Sendable (Data) -> ConfigFileDiagnosis

    private init(
        id: VMBundleStateFileID,
        decode: @escaping @Sendable (Data?, any VMBundleFileReading) throws -> Value,
        encode: @escaping @Sendable (Value) throws -> Data,
        diagnose: @escaping @Sendable (Data) -> ConfigFileDiagnosis
    ) {
        self.id = id
        self.decode = decode
        self.encode = encode
        self.diagnose = diagnose
    }

    var relativePath: String { id.relativePath }

    var fileName: String { (relativePath as NSString).lastPathComponent }

    /// The file's value as `files`, the bundle at `bundleURL`, holds it.
    /// `owner` names the file should it be unreadable; `nil` takes the VM its
    /// own `$.name` names.
    fileprivate func read(
        from files: any VMBundleFileReading, in bundleURL: URL,
        owner: UnreadableConfigFile.Owner? = nil
    ) throws(UnreadableConfigFile) -> Value {
        let data: Data?
        do {
            data = try files.data(atRelativePath: relativePath)
        } catch {
            throw unreadable(
                in: bundleURL, owner: owner, .fileUnreadable(reason: error.localizedDescription))
        }
        return try value(of: data, in: files, bundleURL: bundleURL, owner: owner)
    }

    /// The value `data` decodes to, as this file of the bundle at `bundleURL`.
    ///
    /// A refusal decodes the same bytes again to say why.
    fileprivate func value(
        of data: Data?, in files: any VMBundleFileReading, bundleURL: URL,
        owner: UnreadableConfigFile.Owner? = nil
    ) throws(UnreadableConfigFile) -> Value {
        do {
            return try decode(data, files)
        } catch {
            guard let data else { throw unreadable(in: bundleURL, owner: owner, .fileMissing) }
            throw UnreadableConfigFile(
                location: .bundle(bundleURL, id), owner: owner,
                fallbackName: bundleURL.lastPathComponent, diagnosis: diagnose(data),
                strictFailure: error)
        }
    }

    private func unreadable(
        in bundleURL: URL, owner: UnreadableConfigFile.Owner?, _ issue: ConfigProblem.Issue
    ) -> UnreadableConfigFile {
        UnreadableConfigFile(
            location: .bundle(bundleURL, id),
            owner: owner ?? .virtualMachine(bundleURL.lastPathComponent),
            problems: [ConfigProblem(path: nil, issue: issue)])
    }

    /// A file in the `config.json` coding whose bytes decode as `Record`,
    /// which `assemble` turns into the value; absence reads as `empty()`, or
    /// as no file at all when `empty` is `nil`.
    private static func coded<Record: Codable>(
        _ id: VMBundleStateFileID, as record: Record.Type, empty: (@Sendable () -> Value)?,
        assemble: @escaping @Sendable (Record, any VMBundleFileReading) -> Value,
        encode: @escaping @Sendable (Value) -> Record
    ) -> Self {
        Self(
            id: id,
            decode: { data, files in
                guard let data else {
                    guard let empty else { throw CocoaError(.fileReadNoSuchFile) }
                    return empty()
                }
                return assemble(
                    try VMConfiguration.makeJSONDecoder().decode(Record.self, from: data), files)
            },
            encode: { try VMConfiguration.makeJSONEncoder().encode(encode($0)) },
            diagnose: {
                ConfigFileDiagnosis(
                    decoding: Record.self, from: $0, decoder: VMConfiguration.makeJSONDecoder(),
                    encoder: VMConfiguration.makeJSONEncoder())
            })
    }

    /// A file whose bytes decode as the value itself.
    private static func coded(
        _ id: VMBundleStateFileID, empty: (@Sendable () -> Value)?
    ) -> Self where Value: Codable {
        coded(id, as: Value.self, empty: empty, assemble: { record, _ in record }, encode: { $0 })
    }
}

extension VMBundleStateFile where Value == VMConfiguration {
    static var configuration: Self { coded(.configuration, empty: nil) }

    /// The configuration snapshot `id` was taken under.
    static func snapshotConfiguration(id: UUID) -> Self {
        coded(.snapshotConfiguration(id), empty: nil)
    }
}

extension VMBundleStateFile where Value == VMHostState {
    static var hostState: Self { coded(.hostState) { VMHostState() } }
}

extension VMBundleStateFile where Value == USBAccessoryPairingSet {
    static var usbPairings: Self { coded(.usbPairings) { USBAccessoryPairingSet() } }
}

extension VMBundleStateFile where Value == VMSnapshotManifest {
    /// The manifest, each snapshot carrying the MAC address its own
    /// `config.json` records — read through the same access, since the
    /// manifest does not repeat it.
    static var snapshotManifest: Self {
        coded(
            .snapshotManifest, as: VMSnapshotManifestRecord.self, empty: { VMSnapshotManifest() },
            assemble: { record, files in
                VMSnapshotManifest(
                    snapshots: record.snapshots.map {
                        VMSnapshot($0, network: capturedNetwork(of: $0.id, in: files))
                    },
                    currentID: record.currentID)
            },
            encode: { $0.record })
    }

    /// The network device of the configuration snapshot `id` holds, or `nil`
    /// when it holds none.
    ///
    /// Decodes those keys rather than the whole configuration, so a snapshot
    /// whose configuration no longer decodes still reserves its address.
    private static func capturedNetwork(
        of id: UUID, in files: any VMBundleFileReading
    ) -> VMCapturedNetwork? {
        guard
            let data = try? files.data(
                atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: id))
        else { return nil }
        return try? VMConfiguration.makeJSONDecoder().decode(VMCapturedNetwork.self, from: data)
    }
}

/// One bundle's state files, read and written through a
/// ``VMBundleFileAccessing``.
///
/// Any bundle can be read. A write takes ``VMBundle/CommitKey``, so only a
/// ``VMBundle`` writes a bundle it holds; a bundle still being staged is
/// written through ``VMStagedBundle``, and a file no read can take is
/// rewritten only by ``repair(_:trashingOriginalWith:)``.
///
/// Every write reads the file, applies a change to what the file holds, and
/// replaces it, all under one coordinated write — so a field another process
/// changed since this one last read survives, and a write this process makes
/// is never a copy of stale memory.
struct VMBundleFiles: Sendable {
    let url: URL
    fileprivate let access: any VMBundleFileAccessing

    init(url: URL, access: any VMBundleFileAccessing) {
        self.url = url
        self.access = access
    }

    #if DEBUG
    /// What these files are read and written through.
    var accessForTesting: any VMBundleFileAccessing { access }
    #endif

    /// Reads all four state files in one coordinated read.
    ///
    /// Throws when `config.json`, the host state or the manifest cannot be
    /// read: a bundle whose contents are not known cannot be written. A
    /// pairings file that cannot be read is left in place and answered as
    /// ``VMBundleRead/pairingsUnreadable``, with no pairings; every pairings
    /// write reads it first, so each one fails for as long as it stays that
    /// way.
    func read() throws(UnreadableConfigFile) -> VMBundleRead {
        try reading { files throws(UnreadableConfigFile) in
            let configuration = try VMBundleStateFile.configuration.read(from: files, in: url)
            let owner = UnreadableConfigFile.Owner.virtualMachine(configuration.name)
            var pairings = USBAccessoryPairingSet()
            var pairingsUnreadable: UnreadableConfigFile?
            do throws(UnreadableConfigFile) {
                pairings = try VMBundleStateFile.usbPairings.read(from: files, in: url, owner: owner)
            } catch {
                pairingsUnreadable = error
            }
            return VMBundleRead(
                files: self,
                configuration: configuration,
                hostState: try VMBundleStateFile.hostState.read(from: files, in: url, owner: owner),
                snapshotManifest: try VMBundleStateFile.snapshotManifest.read(
                    from: files, in: url, owner: owner),
                usbPairings: pairings,
                pairingsUnreadable: pairingsUnreadable)
        }
    }

    /// Reads `config.json` alone.
    func readConfiguration() throws(UnreadableConfigFile) -> VMConfiguration {
        try reading { files throws(UnreadableConfigFile) in
            try VMBundleStateFile.configuration.read(from: files, in: url)
        }
    }

    /// Every one of the bundle's state files, and every `config.json` a
    /// snapshot its manifest lists was taken under, that a read refuses —
    /// read fresh, each through the decode the library's own read takes.
    func unreadableFiles() -> [UnreadableConfigFile] {
        do throws(UnreadableConfigFile) {
            return try reading { files throws(UnreadableConfigFile) in
                var found: [UnreadableConfigFile] = []
                func attempt<Value>(
                    _ file: VMBundleStateFile<Value>, owner: UnreadableConfigFile.Owner?
                ) -> Value? {
                    do throws(UnreadableConfigFile) {
                        return try file.read(from: files, in: url, owner: owner)
                    } catch {
                        found.append(error)
                        return nil
                    }
                }
                let configuration = attempt(.configuration, owner: nil)
                let vmName = configuration?.name ?? found.first?.owner.title ?? url.lastPathComponent
                let owner = UnreadableConfigFile.Owner.virtualMachine(vmName)
                _ = attempt(.hostState, owner: owner)
                _ = attempt(.usbPairings, owner: owner)
                let manifest = attempt(.snapshotManifest, owner: owner)
                for snapshot in manifest?.snapshots ?? [] {
                    _ = attempt(
                        .snapshotConfiguration(id: snapshot.id),
                        owner: .snapshot(vm: vmName, snapshot: snapshot.name))
                }
                return found
            }
        } catch {
            return [error]
        }
    }

    /// `body` under a coordinated read, a read that cannot be coordinated
    /// thrown as an unreadable `config.json`.
    private func reading<T>(
        _ body: (any VMBundleFileReading) throws(UnreadableConfigFile) -> T
    ) throws(UnreadableConfigFile) -> T {
        do {
            let outcome = try access.reading(url) { files -> Result<T, UnreadableConfigFile> in
                do throws(UnreadableConfigFile) {
                    return .success(try body(files))
                } catch {
                    return .failure(error)
                }
            }
            return try outcome.get()
        } catch let unreadable as UnreadableConfigFile {
            throw unreadable
        } catch {
            throw UnreadableConfigFile(
                location: .bundle(url, .configuration),
                owner: .virtualMachine(url.lastPathComponent),
                problems: [
                    ConfigProblem(path: nil, issue: .fileUnreadable(reason: error.localizedDescription))
                ])
        }
    }

    /// Takes the run lock on the bundle directory without waiting — `nil` when
    /// another holder has it (``VMBundleFileAccessing/lockBundle(at:)``).
    func lockRun() throws -> (any VMBundleLockHolder)? {
        try access.lockBundle(at: url)
    }

    /// Whether any holder has the bundle directory's run lock
    /// (``VMBundleFileAccessing/isBundleLockedElsewhere(at:)``).
    func isRunLockedElsewhere() throws -> Bool {
        try access.isBundleLockedElsewhere(at: url)
    }

    // periphery:ignore:parameters key - an access token: its type admits the caller
    /// Applies `change` to what `file` holds on disk and replaces the file with
    /// the result, answering the value the file now holds — the commit a
    /// ``VMBundle`` makes, which only it can mint `key` for.
    ///
    /// A change that leaves the value as it was writes nothing. `change` runs
    /// inside the coordinated write, and whatever it throws leaves the file as
    /// it was.
    ///
    /// Unless `holdingRunLock`, a change that moves the value throws
    /// ``VMAdmission/Refusal/heldByAnotherCopy``, leaving the file as it was,
    /// while another copy of Kernova holds the bundle's run lock.
    @discardableResult
    func update<Value>(
        _ file: VMBundleStateFile<Value>, _ key: VMBundle.CommitKey, holdingRunLock: Bool,
        _ change: (inout Value) throws -> Void
    ) throws -> Value {
        try replace(file, refusingAnotherCopysHold: !holdingRunLock, change)
    }

    /// ``update(_:_:holdingRunLock:_:)``'s write, for the two writers this
    /// file admits.
    fileprivate func replace<Value>(
        _ file: VMBundleStateFile<Value>, refusingAnotherCopysHold: Bool,
        _ change: (inout Value) throws -> Void
    ) throws -> Value {
        try access.writing(url, VMBundleFileWriteKey()) { files in
            let current = try file.read(from: files, in: url)
            var new = current
            try change(&new)
            guard new != current else { return current }
            // Inside the coordinated write: another copy's bring-up takes the
            // run lock and then reads the bundle, and a read and a write of one
            // bundle exclude each other, so either that read sees this write or
            // this check sees the lock.
            if refusingAnotherCopysHold, try access.isBundleLockedElsewhere(at: url) {
                throw VMAdmissionRefusal(refusal: .heldByAnotherCopy)
            }
            let encoded = try file.encode(new)
            try files.replace(atRelativePath: file.relativePath, with: encoded)
            // What the file holds, not `new`: the encoding keeps dates to the
            // second, so the two can differ.
            return try file.value(of: encoded, in: files, bundleURL: url)
        }
    }

    /// Puts each problem's default in place in the state file `id` names,
    /// moving what the file held to the Trash first.
    ///
    /// Decides on what the file holds inside the coordinated write, not on
    /// the check that listed it, and refuses while any copy of Kernova holds
    /// the bundle's run lock — the VM is in use. A copy of the bytes goes to
    /// the Trash under the file's own name before the file is replaced, in
    /// one atomic step, so at no point is the file absent or half-written,
    /// and a failure anywhere leaves it as it was.
    func repair(
        _ id: VMBundleStateFileID, trashingOriginalWith fileSystem: any FileSystemOperating
    ) throws -> ConfigFileRepair {
        switch id {
        case .configuration: try repair(VMBundleStateFile.configuration, fileSystem)
        case .hostState: try repair(VMBundleStateFile.hostState, fileSystem)
        case .snapshotManifest: try repair(VMBundleStateFile.snapshotManifest, fileSystem)
        case .usbPairings: try repair(VMBundleStateFile.usbPairings, fileSystem)
        case .snapshotConfiguration(let snapshot):
            try repair(VMBundleStateFile.snapshotConfiguration(id: snapshot), fileSystem)
        }
    }

    private func repair<Value>(
        _ file: VMBundleStateFile<Value>, _ fileSystem: any FileSystemOperating
    ) throws -> ConfigFileRepair {
        try access.writing(url, VMBundleFileWriteKey()) { files in
            guard let data = try files.data(atRelativePath: file.relativePath) else {
                throw ConfigFileRepairRefusal.notRepairable
            }
            if (try? file.value(of: data, in: files, bundleURL: url)) != nil {
                return .alreadyReadable
            }
            guard let repaired = file.diagnose(data).repaired else {
                throw ConfigFileRepairRefusal.notRepairable
            }
            if try access.isBundleLockedElsewhere(at: url) {
                throw ConfigFileRepairRefusal.inUse
            }
            try ConfigFileRepair.moveOriginalToTrash(data, named: file.fileName, using: fileSystem)
            try files.replace(atRelativePath: file.relativePath, with: repaired)
            return .repaired
        }
    }
}

/// A bundle a create, clone or import is still writing: a path minted fresh
/// under the hidden staging directory, which no library listing admits, so no
/// ``VMBundle`` holds it and no permit governs its state files.
///
/// Minted only by ``mint(in:)``, so a registered VM's bundle is never one.
struct VMStagedBundle: Sendable {
    private let files: VMBundleFiles

    private init(url: URL, access: any VMBundleFileAccessing) {
        files = VMBundleFiles(url: url, access: access)
    }

    /// A staged path no write has used, under `storage`'s staging directory.
    static func mint(in storage: any VMStorageProviding) throws -> VMStagedBundle {
        VMStagedBundle(url: try storage.makeStagedBundleURL(), access: storage.bundleFiles)
    }

    var url: URL { files.url }

    var layout: VMBundleLayout { VMBundleLayout(bundleURL: url) }

    /// Writes the bundle's first `config.json`.
    func writeInitial(_ configuration: VMConfiguration) throws {
        let data = try VMBundleStateFile.configuration.encode(configuration)
        try files.access.writing(url, VMBundleFileWriteKey()) {
            try $0.replace(atRelativePath: VMBundleStateFile.configuration.relativePath, with: data)
        }
    }

    /// Applies `change` to what `file` holds, as
    /// ``VMBundleFiles/update(_:_:holdingRunLock:_:)`` does for a held bundle —
    /// which no other copy of Kernova writes, since it lies under this
    /// process's own staging root.
    @discardableResult
    func update<Value>(_ file: VMBundleStateFile<Value>, _ change: (inout Value) throws -> Void)
        throws -> Value
    {
        try files.replace(file, refusingAnotherCopysHold: false, change)
    }

    #if DEBUG
    /// Writes to `url` as a writer no permit governs — a fixture laid down
    /// before any ``VMBundle`` holds the bundle, or another process's write.
    static func fixtureForTesting(at url: URL, access: any VMBundleFileAccessing) -> VMStagedBundle {
        VMStagedBundle(url: url, access: access)
    }
    #endif
}

/// What ``VMBundleFileAccessing/writing(_:_:_:)`` asks for, so only this
/// file — a ``VMBundle``'s commits through ``VMBundleFiles/update(_:_:holdingRunLock:_:)``,
/// a repair, and a ``VMStagedBundle``'s writes — replaces a bundle's state
/// file: the initializer is `fileprivate`, which `@testable import` does not
/// open, and the key is passed `borrowing`, so no conformer can keep one.
struct VMBundleFileWriteKey: ~Copyable {
    fileprivate init() {}
}

/// What one ``VMBundleFiles/read()`` found — the only thing a ``VMBundle`` is
/// built from, so a bundle's committed values always came off disk.
struct VMBundleRead: Sendable {
    let files: VMBundleFiles
    let configuration: VMConfiguration
    let hostState: VMHostState
    let snapshotManifest: VMSnapshotManifest
    let usbPairings: USBAccessoryPairingSet
    /// Why the pairings read as none, when their file is present but could not
    /// be read.
    let pairingsUnreadable: UnreadableConfigFile?

    fileprivate init(
        files: VMBundleFiles, configuration: VMConfiguration, hostState: VMHostState,
        snapshotManifest: VMSnapshotManifest, usbPairings: USBAccessoryPairingSet,
        pairingsUnreadable: UnreadableConfigFile?
    ) {
        self.files = files
        self.configuration = configuration
        self.hostState = hostState
        self.snapshotManifest = snapshotManifest
        self.usbPairings = usbPairings
        self.pairingsUnreadable = pairingsUnreadable
    }
}
