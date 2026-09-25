import Foundation

/// One VM bundle's state files — `config.json`, `host-state.json`,
/// `Snapshots/manifest.json` and `usb-accessories.json` — and the values last
/// committed to them.
///
/// The only reader and writer of those files. Built only from a
/// ``VMBundleRead``, so it exists only for a bundle already on disk, and each
/// value it holds is one a coordinated read found or a committed write left on
/// disk: memory never holds a value disk lacks.
///
/// A commit reads the file, applies its change to what the file holds, replaces
/// the file, and only then publishes the new value; one that throws leaves the
/// value as it was. The change runs inside the coordinated write, so it must be
/// pure — no UI, no suspension, no second access to this bundle.
@MainActor
@Observable
final class VMBundle {
    @ObservationIgnored private let files: VMBundleFiles

    var url: URL { files.url }

    #if DEBUG
    /// What this bundle's files are read and written through.
    ///
    /// Test-only seam: a test registering a fixture VM with a library points
    /// the fixture's in-memory files at the library's storage through it.
    var fileAccessForTesting: any VMBundleFileAccessing { files.access }
    #endif

    private(set) var configuration: VMConfiguration
    private(set) var hostState: VMHostState
    private(set) var snapshotManifest: VMSnapshotManifest
    private(set) var usbPairings: USBAccessoryPairingSet

    init(_ read: VMBundleRead) {
        files = read.files
        configuration = read.configuration
        hostState = read.hostState
        snapshotManifest = read.snapshotManifest
        usbPairings = read.usbPairings
    }

    /// Sets a committed value only when it moved, so a no-op write wakes no
    /// observer.
    private func publish<Value: Equatable>(
        _ value: Value, to keyPath: ReferenceWritableKeyPath<VMBundle, Value>
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    /// Commits `change` to `config.json`; `key` confines the call to
    /// ``VMLibrary``, which owns the refusals a configuration write passes.
    func commitConfiguration(
        key _: VMLibrary.ConfigurationWriteKey, _ change: (inout VMConfiguration) throws -> Void
    ) throws {
        publish(try files.update(.configuration, change), to: \.configuration)
    }

    func commitHostState(_ change: (inout VMHostState) throws -> Void) throws {
        publish(try files.update(.hostState, change), to: \.hostState)
    }

    func commitSnapshotManifest(_ change: (inout VMSnapshotManifest) throws -> Void) throws {
        publish(try files.update(.snapshotManifest, change), to: \.snapshotManifest)
    }

    func commitUSBPairings(_ change: (inout USBAccessoryPairingSet) throws -> Void) throws {
        publish(try files.update(.usbPairings, change), to: \.usbPairings)
    }
}
