import FileProvider
import Foundation
import UniformTypeIdentifiers
import os

// SPIKE (#424 Phase 0) — THROWAWAY host File Provider extension.
//
// Sole purpose: prove that a sandboxed File Provider extension embedded in the
// MAIN Kernova app can reach the *non-LaunchAgent* main app over an app-group
// Mach service, in a SIGNED, INSTALLED build. Apple DTS says a non-launchd app
// can't reliably register an NSXPCListener; D1a's guest worked only because the
// agent is a LaunchAgent. The host app isn't. This canned extension + the main
// app's canned listener (HostClipboardFileProviderSpike.swift) answer that one
// question before the real wiring is built. Everything here is deleted/replaced
// once the verdict is in.
//
// It is self-contained (no KernovaKit dependency) so the spike isolates the XPC
// variable: one hard-coded item, fetchContents relays to the main app, the main
// app stages 8 MiB into the shared group container after a deliberate 90 s delay
// and replies the path (also tests app-group container sharing + no-deadline).

/// The XPC contract the spike relay vends.
///
/// Declared identically on both sides (the main app's spike listener) — @objc
/// protocols match by selector.
@objc protocol HostClipboardRelaySpike {
    func fetchSpikeBytes(reply: @escaping @Sendable (_ stagedPath: String?, _ error: NSError?) -> Void)
}

private enum SpikeConfig {
    /// App-group-prefixed Mach service the main app vends.
    ///
    /// Distinct from the guest's `…relay` so a dev host running both never
    /// collides; still an immediate child of the shared group `8MT4P4GZL2.app.kernova`.
    static let machServiceName = "8MT4P4GZL2.app.kernova.hostrelay"
    static let itemIdentifier = "spike-host"
    static let filename = "SpikeHostFile.bin"
    static let byteCount = 8 * 1024 * 1024
}

/// The principal class the system instantiates per registered host domain.
final class HostFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    static let logger = Logger(
        subsystem: "app.kernova.clipboard.fileprovider", category: "SpikeExtension")

    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        Self.logger.notice(
            "HostFileProviderExtension(spike) init (domain=\(domain.identifier.rawValue, privacy: .public))"
        )
    }

    func invalidate() {
        Self.logger.notice("HostFileProviderExtension(spike) invalidate")
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        if identifier == .rootContainer {
            completionHandler(SpikeRootItem(), nil)
        } else if identifier.rawValue == SpikeConfig.itemIdentifier {
            completionHandler(SpikeFileItem(), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        Self.logger.notice(
            "fetchContents(spike) START (item=\(itemIdentifier.rawValue, privacy: .public))")
        let progress = Progress(totalUnitCount: 100)
        guard itemIdentifier.rawValue == SpikeConfig.itemIdentifier else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let connection = NSXPCConnection(machServiceName: SpikeConfig.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: HostClipboardRelaySpike.self)
        connection.resume()
        defer { connection.invalidate() }

        final class Outcome: @unchecked Sendable {
            var path: String?
            var error: Error?
        }
        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)

        let proxy =
            connection.remoteObjectProxyWithErrorHandler { error in
                outcome.error = error
                semaphore.signal()
            } as? HostClipboardRelaySpike
        guard let proxy else {
            Self.logger.error("fetchContents(spike) no proxy")
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            return progress
        }

        proxy.fetchSpikeBytes { path, error in
            outcome.path = path
            outcome.error = error
            semaphore.signal()
        }
        semaphore.wait()

        guard let stagedPath = outcome.path else {
            Self.logger.error(
                "fetchContents(spike) relay failed: \(outcome.error?.localizedDescription ?? "unknown", privacy: .public)"
            )
            completionHandler(nil, nil, outcome.error ?? NSFileProviderError(.serverUnreachable))
            return progress
        }

        guard let manager = NSFileProviderManager(for: domain) else {
            completionHandler(nil, nil, NSFileProviderError(.providerNotFound))
            return progress
        }
        do {
            let tempDir = try manager.temporaryDirectoryURL()
            let destination = tempDir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: stagedPath), to: destination)
            Self.logger.notice("fetchContents(spike) materialized via \(stagedPath, privacy: .public)")
            progress.completedUnitCount = 100
            completionHandler(destination, SpikeFileItem(), nil)
        } catch {
            Self.logger.error(
                "fetchContents(spike) clone failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, nil, error)
        }
        return progress
    }

    // The spike domain is read-only.

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
        contents url: URL?, options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler:
            @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) ->
            Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler:
            @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) ->
            Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        SpikeEnumerator(container: containerItemIdentifier)
    }
}

final class SpikeRootItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "Kernova Clipboard (Host Spike)" }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    var contentType: UTType { .folder }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

final class SpikeFileItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(SpikeConfig.itemIdentifier)
    }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { SpikeConfig.filename }
    var capabilities: NSFileProviderItemCapabilities { .allowsAll }
    var contentType: UTType { .data }
    var documentSize: NSNumber? { NSNumber(value: SpikeConfig.byteCount) }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

final class SpikeEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
        super.init()
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        if container == .rootContainer || container == .workingSet {
            observer.didEnumerate([SpikeFileItem()])
        }
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("spike-1".utf8)))
    }
}
