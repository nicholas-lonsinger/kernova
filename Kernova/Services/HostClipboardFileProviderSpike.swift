import AppKit
import FileProvider
import Foundation
import os

// SPIKE (#424 Phase 0) — THROWAWAY main-app side of the host File Provider XPC
// probe. See KernovaClipboardFileProvider/HostFileProviderExtension.swift for the
// full rationale. This stands up the host domain and vends the app-group Mach
// relay from the *non-LaunchAgent* main app; the one question is whether the
// sandboxed extension can reach it in a signed, installed build. Replaced by the
// real ClipboardFileProviderDomainHost wiring once the verdict is in.
//
// Gated behind a launch argument so it never runs in normal app operation.

/// The XPC contract the spike relay vends.
///
/// Declared identically in the extension (@objc protocols match by selector).
@objc protocol HostClipboardRelaySpike {
    func fetchSpikeBytes(reply: @escaping @Sendable (_ stagedPath: String?, _ error: NSError?) -> Void)
}

enum HostClipboardFileProviderSpike {
    /// Pass `--clipboard-fileprovider-host-spike` to the app to run the probe.
    static let launchArgument = "--clipboard-fileprovider-host-spike"

    /// Pass `--clipboard-fileprovider-host-spike-remove` to tear the host spike
    /// domain down (just this one, not the guest's) and terminate.
    static let removeArgument = "--clipboard-fileprovider-host-spike-remove"

    private static let machServiceName = "8MT4P4GZL2.app.kernova.hostrelay"
    private static let appGroupIdentifier = "8MT4P4GZL2.app.kernova"
    private static let domainIdentifier = NSFileProviderDomainIdentifier("kernova-clipboard-host")
    private static let domainDisplayName = "Kernova Clipboard (Host Spike)"
    private static let byteCount = 8 * 1024 * 1024
    /// Deliberate delay to prove fetchContents has no 60 s deadline (like D1a).
    private static let relayDelaySeconds: UInt32 = 90

    private static let logger = Logger(
        subsystem: "app.kernova", category: "HostFileProviderSpike")

    // Retained for the process lifetime so the listener keeps serving.
    private static let listenerHolder = ListenerHolder()

    /// Stands up the host domain + the app-group Mach listener if requested.
    ///
    /// Runs only when the launch argument is present. Call from
    /// `applicationDidFinishLaunching`.
    static func runIfRequested() {
        if CommandLine.arguments.contains(removeArgument) {
            removeDomainThenTerminate()
            return
        }
        guard CommandLine.arguments.contains(launchArgument) else { return }
        logger.notice("Host File Provider spike starting")
        startListener()
        registerDomain()
    }

    /// Removes only the host spike domain (by identifier) and terminates, so a
    /// teardown leaves the guest agent's domain untouched.
    private static func removeDomainThenTerminate() {
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: domainDisplayName)
        NSFileProviderManager.remove(domain) { error in
            if let error {
                logger.error("Spike remove domain failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.notice("Spike domain removed")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func startListener() {
        let listener = NSXPCListener(machServiceName: machServiceName)
        let delegate = SpikeListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        listenerHolder.listener = listener
        listenerHolder.delegate = delegate
        logger.notice("Spike XPC listener started (\(machServiceName, privacy: .public))")
    }

    private static func registerDomain() {
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: domainDisplayName)
        NSFileProviderManager.add(domain) { error in
            if let error {
                logger.error("Spike add domain failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            logger.notice("Spike domain registered: \(domainIdentifier.rawValue, privacy: .public)")
            guard let manager = NSFileProviderManager(for: domain) else { return }
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let url {
                    logger.notice("Spike domain visible at: \(url.path, privacy: .public)")
                    forceRootEnumeration(url)
                } else if let error {
                    logger.error(
                        "Spike getUserVisibleURL failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Forces the root readdir that writes the dataless placeholder to disk (the
    /// D1a gotcha: signalEnumerator alone won't create the on-disk dirent).
    private static func forceRootEnumeration(_ root: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            logger.notice("Spike root listing: \(entries?.count ?? -1, privacy: .public) entr(ies)")
        }
    }

    /// Stages the canned payload into the shared group container after the delay
    /// and returns its path — also exercising group-container sharing + no-deadline.
    fileprivate static func stageCannedFile() -> Result<String, NSError> {
        sleep(relayDelaySeconds)
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else {
            return .failure(
                NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.providerNotFound.rawValue))
        }
        let stagingDir = container.appendingPathComponent("FileProviderHost/staging", isDirectory: true)
        let dest = stagingDir.appendingPathComponent("\(UUID().uuidString).bin")
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try Data(count: byteCount).write(to: dest, options: .atomic)
            logger.notice("Spike staged \(byteCount, privacy: .public) bytes at \(dest.path, privacy: .public)")
            return .success(dest.path)
        } catch {
            logger.error("Spike staging failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error as NSError)
        }
    }

    /// Holds the listener + delegate alive for the process lifetime.
    private final class ListenerHolder: @unchecked Sendable {
        var listener: NSXPCListener?
        var delegate: SpikeListenerDelegate?
    }
}

private final class SpikeListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HostClipboardRelaySpike.self)
        newConnection.exportedObject = SpikeRelayService()
        newConnection.resume()
        return true
    }
}

private final class SpikeRelayService: NSObject, HostClipboardRelaySpike {
    func fetchSpikeBytes(reply: @escaping @Sendable (String?, NSError?) -> Void) {
        // Runs off-main on the XPC queue; the File Provider read path has no
        // deadline, so the deliberate 90 s sleep inside stageCannedFile is safe.
        switch HostClipboardFileProviderSpike.stageCannedFile() {
        case .success(let path): reply(path, nil)
        case .failure(let error): reply(nil, error)
        }
    }
}
