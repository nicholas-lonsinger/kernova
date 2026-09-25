import Foundation

/// A state file a VM bundle holds, which only ``VMBundleFiles`` reads and
/// replaces: where it lives in the bundle and how its bytes map to a value.
///
/// Absence reads as the default for every file but `config.json`, whose absence
/// means there is no VM to read. A file that is present but cannot be read or
/// decoded throws ``UnreadableBundleFile``, so nothing can mistake it for the
/// default a later write would put over it.
struct VMBundleStateFile<Value: Equatable & Sendable>: Sendable {
    let relativePath: String
    /// Decodes the file's bytes, `nil` when the bundle holds no such file.
    /// `files` is the same coordinated access, for a value assembled from
    /// more than one file.
    private let decode: @Sendable (_ data: Data?, _ files: any VMBundleFileReading) throws -> Value
    fileprivate let encode: @Sendable (Value) throws -> Data

    private init(
        relativePath: String,
        decode: @escaping @Sendable (Data?, any VMBundleFileReading) throws -> Value,
        encode: @escaping @Sendable (Value) throws -> Data
    ) {
        self.relativePath = relativePath
        self.decode = decode
        self.encode = encode
    }

    var fileName: String { (relativePath as NSString).lastPathComponent }

    /// The file's value as `files` holds it.
    fileprivate func read(from files: any VMBundleFileReading) throws -> Value {
        try value(of: try files.data(atRelativePath: relativePath), in: files)
    }

    /// The value `data` decodes to, as the file at ``relativePath`` in `files`.
    fileprivate func value(of data: @autoclosure () throws -> Data?, in files: any VMBundleFileReading)
        throws -> Value
    {
        do {
            return try decode(try data(), files)
        } catch let unreadable as UnreadableBundleFile {
            throw unreadable
        } catch {
            throw UnreadableBundleFile(fileName: fileName, underlying: error)
        }
    }

    /// A sidecar in the `config.json` coding whose absence reads as `empty`.
    private static func sidecar(
        at relativePath: String, empty: @escaping @Sendable () -> Value
    ) -> Self where Value: Codable {
        Self(
            relativePath: relativePath,
            decode: { data, _ in
                guard let data else { return empty() }
                return try VMConfiguration.makeJSONDecoder().decode(Value.self, from: data)
            },
            encode: { try VMConfiguration.makeJSONEncoder().encode($0) })
    }
}

extension VMBundleStateFile where Value == VMConfiguration {
    static var configuration: Self {
        Self(
            relativePath: VMBundleLayout.configRelativePath,
            decode: { data, _ in
                guard let data else { throw CocoaError(.fileReadNoSuchFile) }
                return try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)
            },
            encode: { try VMConfiguration.makeJSONEncoder().encode($0) })
    }
}

extension VMBundleStateFile where Value == VMHostState {
    static var hostState: Self {
        sidecar(at: VMBundleLayout.hostStateRelativePath) { VMHostState() }
    }
}

extension VMBundleStateFile where Value == USBAccessoryPairingSet {
    static var usbPairings: Self {
        sidecar(at: VMBundleLayout.usbPairingsRelativePath) { USBAccessoryPairingSet() }
    }
}

extension VMBundleStateFile where Value == VMSnapshotManifest {
    /// The manifest, each snapshot carrying the MAC address its own
    /// `config.json` records — read through the same access, since the
    /// manifest does not repeat it.
    static var snapshotManifest: Self {
        Self(
            relativePath: VMBundleLayout.snapshotManifestRelativePath,
            decode: { data, files in
                guard let data else { return VMSnapshotManifest() }
                let record = try VMConfiguration.makeJSONDecoder().decode(
                    VMSnapshotManifestRecord.self, from: data)
                return VMSnapshotManifest(
                    snapshots: record.snapshots.map {
                        VMSnapshot($0, macAddress: capturedMACAddress(of: $0.id, in: files))
                    },
                    currentID: record.currentID)
            },
            encode: { try VMConfiguration.makeJSONEncoder().encode($0.record) })
    }

    /// The `macAddress` of the configuration snapshot `id` holds, or `nil` when
    /// it holds none or carries no address.
    ///
    /// Decodes that one key rather than the whole configuration, so a snapshot
    /// whose configuration no longer decodes still reserves its address.
    private static func capturedMACAddress(
        of id: UUID, in files: any VMBundleFileReading
    ) -> String? {
        guard
            let data = try? files.data(
                atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: id))
        else { return nil }
        return (try? VMConfiguration.makeJSONDecoder().decode(CapturedAddress.self, from: data))?
            .macAddress
    }
}

/// The one key of a snapshot's configuration its manifest entry needs.
private struct CapturedAddress: Decodable {
    let macAddress: String?
}

/// A bundle state file that is present but could not be read or decoded — or,
/// for `config.json`, absent.
struct UnreadableBundleFile: LocalizedError {
    let fileName: String
    let underlying: any Error

    var errorDescription: String? {
        "\u{201C}\(fileName)\u{201D} could not be read: \(underlying.localizedDescription)"
    }
}

/// One bundle's state files, read and written through a
/// ``VMBundleFileAccessing``.
///
/// Every write reads the file, applies a change to what the file holds, and
/// replaces it, all under one coordinated write — so a field another process
/// changed since this one last read survives, and a write this process makes
/// is never a copy of stale memory.
struct VMBundleFiles: Sendable {
    let url: URL
    let access: any VMBundleFileAccessing

    /// Reads all four state files in one coordinated read.
    ///
    /// Throws when `config.json`, the host state or the manifest cannot be
    /// read: a bundle whose contents are not known cannot be written. A
    /// pairings file that cannot be read is left in place and answered as
    /// ``VMBundleRead/pairingsUnreadable``, with no pairings — a pairing is made
    /// again by attaching the device once.
    func read() throws -> VMBundleRead {
        try access.reading(url) { files in
            var pairings = USBAccessoryPairingSet()
            var pairingsUnreadable: UnreadableBundleFile?
            do {
                pairings = try VMBundleStateFile.usbPairings.read(from: files)
            } catch let unreadable as UnreadableBundleFile {
                pairingsUnreadable = unreadable
            }
            return VMBundleRead(
                files: self,
                configuration: try VMBundleStateFile.configuration.read(from: files),
                hostState: try VMBundleStateFile.hostState.read(from: files),
                snapshotManifest: try VMBundleStateFile.snapshotManifest.read(from: files),
                usbPairings: pairings,
                pairingsUnreadable: pairingsUnreadable)
        }
    }

    /// Reads `config.json` alone.
    func readConfiguration() throws -> VMConfiguration {
        try access.reading(url) { try VMBundleStateFile.configuration.read(from: $0) }
    }

    /// Applies `change` to what `file` holds on disk and replaces the file with
    /// the result, answering the value the file now holds.
    ///
    /// A change that leaves the value as it was writes nothing. `change` runs
    /// inside the coordinated write, and whatever it throws leaves the file as
    /// it was.
    @discardableResult
    func update<Value>(_ file: VMBundleStateFile<Value>, _ change: (inout Value) throws -> Void) throws
        -> Value
    {
        try access.writing(url) { files in
            let current = try file.read(from: files)
            var new = current
            try change(&new)
            guard new != current else { return current }
            let encoded = try file.encode(new)
            try files.replace(atRelativePath: file.relativePath, with: encoded)
            // What the file holds, not `new`: the encoding keeps dates to the
            // second, so the two can differ.
            return try file.value(of: encoded, in: files)
        }
    }

    /// Writes the first `config.json` of a bundle still being staged, which no
    /// ``VMBundle`` can hold yet.
    func writeInitial(_ configuration: VMConfiguration) throws {
        let data = try VMBundleStateFile.configuration.encode(configuration)
        try access.writing(url) {
            try $0.replace(atRelativePath: VMBundleStateFile.configuration.relativePath, with: data)
        }
    }
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
    let pairingsUnreadable: UnreadableBundleFile?

    fileprivate init(
        files: VMBundleFiles, configuration: VMConfiguration, hostState: VMHostState,
        snapshotManifest: VMSnapshotManifest, usbPairings: USBAccessoryPairingSet,
        pairingsUnreadable: UnreadableBundleFile?
    ) {
        self.files = files
        self.configuration = configuration
        self.hostState = hostState
        self.snapshotManifest = snapshotManifest
        self.usbPairings = usbPairings
        self.pairingsUnreadable = pairingsUnreadable
    }

    /// The same read, of the bundle a rename has just moved to `url` — the
    /// bytes a publication moves are exactly the ones read.
    func relocated(to url: URL) -> VMBundleRead {
        VMBundleRead(
            files: VMBundleFiles(url: url, access: files.access), configuration: configuration,
            hostState: hostState, snapshotManifest: snapshotManifest, usbPairings: usbPairings,
            pairingsUnreadable: pairingsUnreadable)
    }
}
