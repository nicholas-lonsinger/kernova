import Foundation
import KernovaKit

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
            return try decoded(data, in: files)
        } catch {
            throw unreadable(refusing: data, with: error, in: bundleURL, owner: owner)
        }
    }

    /// The value `data` decodes to, throwing what the strict decode threw.
    fileprivate func decoded(_ data: Data?, in files: any VMBundleFileReading) throws -> Value {
        try decode(data, files)
    }

    /// `data` as the strict decode that threw `error` refused it, as this
    /// file of the bundle at `bundleURL`; the bytes are decoded again to say
    /// why.
    fileprivate func unreadable(
        refusing data: Data?, with error: any Error, in bundleURL: URL, owner: UnreadableConfigFile.Owner?
    ) -> UnreadableConfigFile {
        guard let data else { return unreadable(in: bundleURL, owner: owner, .fileMissing) }
        return UnreadableConfigFile(
            location: .bundle(bundleURL, id), owner: owner,
            fallbackName: bundleURL.lastPathComponent, diagnosis: diagnose(data),
            strictFailure: error)
    }

    fileprivate func unreadable(
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
        coded(
            .snapshotConfiguration(id), as: VMSnapshotConfigurationRecord.self, empty: nil,
            assemble: { record, _ in record.configuration },
            encode: { VMSnapshotConfigurationRecord(configuration: $0) })
    }
}

/// A snapshot's `config.json`: the configuration it was taken under, whose
/// network device is read as the facts ``VMCapturedNetwork`` holds as well —
/// so the check lists an unrecognized one as a problem no default repairs.
private struct VMSnapshotConfigurationRecord: Codable {
    let configuration: VMConfiguration

    init(configuration: VMConfiguration) {
        self.configuration = configuration
    }

    init(from decoder: any Decoder) throws {
        configuration = try VMConfiguration(from: decoder)
        _ = try VMCapturedNetwork(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try configuration.encode(to: encoder)
    }
}

/// A snapshot's `config.json`, its bytes read once, and the two things a
/// bundle read takes from them: the network device the snapshot reserves an
/// address for, and whether a strict read refuses the file.
private struct VMSnapshotConfigurationRead {
    private let file: VMBundleStateFile<VMConfiguration>
    /// The bytes, `nil` when there is no file; the read's error when there is
    /// one that could not be read.
    private let bytes: Result<Data?, any Error>
    /// What the strict decode of the bytes threw, `nil` when they decoded.
    private let refusal: (any Error)?

    /// The snapshot's network device: its configuration's when that reads,
    /// else what ``JSONDecoder/decodeRepairing(_:from:)`` reads of the bytes,
    /// and `nil` when there are no bytes to read.
    let network: VMCapturedNetwork?

    init(of id: UUID, in files: any VMBundleFileReading) {
        let file = VMBundleStateFile.snapshotConfiguration(id: id)
        self.file = file
        bytes = Result { try files.data(atRelativePath: file.relativePath) }
        guard case .success(let data) = bytes else {
            refusal = nil
            network = nil
            return
        }
        do {
            network = VMCapturedNetwork(try file.decoded(data, in: files))
            refusal = nil
        } catch {
            refusal = error
            network = data.flatMap {
                try? VMConfiguration.makeJSONDecoder().decodeRepairing(VMCapturedNetwork.self, from: $0)
            }
        }
    }

    /// The file as a strict read refuses it, in the bundle at `bundleURL`;
    /// `nil` when it reads.
    func unreadable(in bundleURL: URL, owner: UnreadableConfigFile.Owner) -> UnreadableConfigFile? {
        switch bytes {
        case .failure(let error):
            file.unreadable(in: bundleURL, owner: owner, .fileUnreadable(reason: error.localizedDescription))
        case .success(let data):
            refusal.map { file.unreadable(refusing: data, with: $0, in: bundleURL, owner: owner) }
        }
    }
}

extension VMBundleStateFile where Value == VMHostState {
    static var hostState: Self { coded(.hostState) { VMHostState() } }
}

extension VMBundleStateFile where Value == USBAccessoryPairingSet {
    static var usbPairings: Self { coded(.usbPairings) { USBAccessoryPairingSet() } }
}

extension VMBundleStateFile where Value == VMSnapshotManifestRecord {
    /// The manifest as the file records it, without the network device each
    /// snapshot's own `config.json` holds.
    static var snapshotManifestRecord: Self {
        coded(.snapshotManifest) { VMSnapshotManifestRecord(snapshots: [], currentID: nil) }
    }
}

extension VMBundleStateFile where Value == VMSnapshotManifest {
    /// The manifest, each snapshot carrying the network device its own
    /// `config.json` records — read through the same access, since the
    /// manifest does not repeat it.
    static var snapshotManifest: Self {
        coded(
            .snapshotManifest, as: VMSnapshotManifestRecord.self, empty: { VMSnapshotManifest() },
            assemble: { record, files in
                assembled(record, reads: record.snapshots.map { VMSnapshotConfigurationRead(of: $0.id, in: files) })
            },
            encode: { $0.record })
    }

    /// `record` with each snapshot carrying the network device `reads` — one
    /// per snapshot, in order — found in its `config.json`.
    fileprivate static func assembled(
        _ record: VMSnapshotManifestRecord, reads: [VMSnapshotConfigurationRead]
    ) -> VMSnapshotManifest {
        VMSnapshotManifest(
            snapshots: zip(record.snapshots, reads).map { VMSnapshot($0, network: $1.network) },
            currentID: record.currentID)
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

    /// Reads every state file, and every `config.json` a snapshot the
    /// manifest lists was taken under, in one coordinated read.
    ///
    /// Throws when `config.json`, the host state or the manifest cannot be
    /// read: a bundle whose contents are not known cannot be written. A
    /// pairings file or a snapshot's `config.json` that cannot be read is
    /// left in place and listed in ``VMBundleRead/unreadableFiles`` — the
    /// pairings read as none, and every pairings write reads the file first,
    /// so each one fails for as long as it stays that way.
    func read() throws(UnreadableConfigFile) -> VMBundleRead {
        try reading { files throws(UnreadableConfigFile) in
            let pass = ReadPass(bundleURL: url, files: files)
            let core = try pass.core.get()
            return VMBundleRead(
                files: self, configuration: core.configuration, hostState: core.hostState,
                snapshotManifest: core.snapshotManifest,
                usbPairings: pass.usbPairings ?? USBAccessoryPairingSet(), unreadableFiles: pass.unreadable)
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
            return try reading { files in ReadPass(bundleURL: url, files: files).unreadable }
        } catch {
            return [error]
        }
    }

    /// Refuses unless the bundle is still unreadable as `checked`, the file
    /// that kept it out, was found: a bundle read still refuses it, and the
    /// file still holds the bytes the check reported — or still none.
    ///
    /// Throws ``ConfigFileRepairRefusal/readsNow`` for a bundle a read takes,
    /// and ``ConfigFileRepairRefusal/changedSinceCheck`` for one whose file
    /// holds other bytes.
    func confirmUnreadable(as checked: UnreadableConfigFile) throws {
        guard case .bundle(_, let id) = checked.location else {
            assertionFailure("A bundle is kept out only by a file of its own")
            throw ConfigFileRepairRefusal.changedSinceCheck
        }
        try access.reading(url) { files in
            if case .success = ReadPass(bundleURL: url, files: files).core {
                throw ConfigFileRepairRefusal.readsNow
            }
            let current = (try? files.data(atRelativePath: id.relativePath)).flatMap { $0 }
            guard current.map(ConfigFileDigest.init(of:)) == checked.checkedDigest else {
                throw ConfigFileRepairRefusal.changedSinceCheck
            }
        }
    }

    /// One attempt at every file a bundle read takes, in the order
    /// ``read()`` needs them, recording each file it could not read.
    private struct ReadPass {
        /// The files no write can do without — or the first of them a read
        /// refused.
        let core:
            Result<
                (configuration: VMConfiguration, hostState: VMHostState, snapshotManifest: VMSnapshotManifest),
                UnreadableConfigFile
            >
        let usbPairings: USBAccessoryPairingSet?
        /// Every file a read refused, in the order it met them.
        let unreadable: [UnreadableConfigFile]

        init(bundleURL: URL, files: any VMBundleFileReading) {
            var found: [UnreadableConfigFile] = []
            func attempt<Value>(
                _ file: VMBundleStateFile<Value>, owner: UnreadableConfigFile.Owner?
            ) -> Result<Value, UnreadableConfigFile> {
                do throws(UnreadableConfigFile) {
                    return .success(try file.read(from: files, in: bundleURL, owner: owner))
                } catch {
                    found.append(error)
                    return .failure(error)
                }
            }
            let configuration = attempt(.configuration, owner: nil)
            let vmName =
                (try? configuration.get().name) ?? found.first?.owner.title ?? bundleURL.lastPathComponent
            let owner = UnreadableConfigFile.Owner.virtualMachine(vmName)
            let hostState = attempt(.hostState, owner: owner)
            let manifestRecord = attempt(.snapshotManifestRecord, owner: owner)
            usbPairings = try? attempt(.usbPairings, owner: owner).get()
            // Each snapshot's `config.json` is read once, for both the network
            // device the manifest carries and whether the file reads.
            let snapshotManifest = manifestRecord.map { record in
                let reads = record.snapshots.map { snapshot in
                    let read = VMSnapshotConfigurationRead(of: snapshot.id, in: files)
                    if let unreadable = read.unreadable(
                        in: bundleURL, owner: .snapshot(vm: vmName, snapshot: snapshot.name))
                    {
                        found.append(unreadable)
                    }
                    return read
                }
                return VMBundleStateFile<VMSnapshotManifest>.assembled(record, reads: reads)
            }
            core = configuration.flatMap { configuration in
                hostState.flatMap { hostState in
                    snapshotManifest.map { (configuration, hostState, $0) }
                }
            }
            unreadable = found
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

    /// Makes each repair the check listed for the state file `id` names —
    /// `checked`, as the check found it — moving what the file held to the
    /// Trash first.
    ///
    /// Decides on what the file holds inside the coordinated write
    /// (``ConfigFileRepair/replacement(for:current:reads:diagnose:)``), and
    /// refuses while any copy of Kernova holds the bundle's run lock — the VM
    /// is in use. A copy of the bytes goes to the Trash before the file is
    /// replaced, in one atomic step, so at no point is the file absent or
    /// half-written, and a failure anywhere leaves it as it was.
    func repair(
        _ id: VMBundleStateFileID, as checked: UnreadableConfigFile,
        trashingOriginalWith fileSystem: any FileSystemOperating
    ) throws -> ConfigFileRepair {
        switch id {
        case .configuration: try repair(VMBundleStateFile.configuration, checked, fileSystem)
        case .hostState: try repair(VMBundleStateFile.hostState, checked, fileSystem)
        case .snapshotManifest: try repair(VMBundleStateFile.snapshotManifest, checked, fileSystem)
        case .usbPairings: try repair(VMBundleStateFile.usbPairings, checked, fileSystem)
        case .snapshotConfiguration(let snapshot):
            try repair(VMBundleStateFile.snapshotConfiguration(id: snapshot), checked, fileSystem)
        }
    }

    private func repair<Value>(
        _ file: VMBundleStateFile<Value>, _ checked: UnreadableConfigFile,
        _ fileSystem: any FileSystemOperating
    ) throws -> ConfigFileRepair {
        try access.writing(url, VMBundleFileWriteKey()) { files in
            let current = try files.data(atRelativePath: file.relativePath)
            guard
                let replacement = try ConfigFileRepair.replacement(
                    for: checked, current: current,
                    reads: { (try? file.value(of: $0, in: files, bundleURL: url)) != nil },
                    diagnose: file.diagnose)
            else { return .alreadyReadable }
            if try access.isBundleLockedElsewhere(at: url) {
                throw ConfigFileRepairRefusal.inUse
            }
            try ConfigFileRepair.moveOriginalToTrash(
                replacement.original, named: checked.trashedOriginalName, using: fileSystem)
            try files.replace(atRelativePath: file.relativePath, with: replacement.repaired)
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
    /// The bundle's files the read left in place because it could not read
    /// them — the pairings, which then read as none, and snapshots'
    /// configurations.
    let unreadableFiles: [UnreadableConfigFile]

    fileprivate init(
        files: VMBundleFiles, configuration: VMConfiguration, hostState: VMHostState,
        snapshotManifest: VMSnapshotManifest, usbPairings: USBAccessoryPairingSet,
        unreadableFiles: [UnreadableConfigFile]
    ) {
        self.files = files
        self.configuration = configuration
        self.hostState = hostState
        self.snapshotManifest = snapshotManifest
        self.usbPairings = usbPairings
        self.unreadableFiles = unreadableFiles
    }
}
