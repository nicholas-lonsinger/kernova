import Foundation
import KernovaAgentCore
import KernovaWire

@testable import KernovaCore

extension GuestAgentDiskCache {
    /// A cache under `/var/empty`, which no write reaches: a test that makes
    /// the Linux disk passes a scratch one instead.
    package static let testing = GuestAgentDiskCache(
        directory: URL(filePath: "/var/empty/GuestAgentDisks", directoryHint: .isDirectory),
        files: URL(filePath: "/var/empty/LinuxAgentDisk", directoryHint: .isDirectory))
}

extension BundledGuestAgents {
    /// No agent at all.
    package static let none = BundledGuestAgents(entries: [:], linuxDisk: .testing)

    /// Only a Linux agent, the file at `agent`, whose disk `disk` writes.
    package static func linux(agent: URL, disk: GuestAgentDiskCache, versionLabel: String = "1.0 (1)")
        -> BundledGuestAgents
    {
        var entries: [BundledGuestAgentKey: BundledGuestAgentEntry] = [:]
        for scope in [InstallScope.user, .system] {
            entries[BundledGuestAgentKey(.linux, .arm64, scope)] = BundledGuestAgentEntry(
                fileURL: agent, kind: .payload(.executable, versionLabel: versionLabel))
        }
        return BundledGuestAgents(entries: entries, linuxDisk: disk)
    }

    /// A macOS agent at version 2.0 whose installer image stands in as a small
    /// file every Mac holds: the core only reads it, copying it into a VM's
    /// bundle when the disk is attached. No Linux agent.
    package static let testing = macOS(
        version: "2.0", installerDiskImageURL: URL(filePath: "/System/Library/CoreServices/SystemVersion.plist"))

    /// Only a macOS agent at `version` with its installer at
    /// `installerDiskImageURL`, or no agent at all when that is `nil`.
    package static func macOS(version: String, installerDiskImageURL: URL?) -> BundledGuestAgents {
        var entries: [BundledGuestAgentKey: BundledGuestAgentEntry] = [:]
        if let installerDiskImageURL {
            entries[BundledGuestAgentKey(.macOS, .arm64, .user)] = BundledGuestAgentEntry(
                fileURL: installerDiskImageURL, kind: .installerDisk(version: version))
        }
        return BundledGuestAgents(entries: entries, linuxDisk: .testing)
    }
}

extension AppBundleProducts {
    /// The products of an app under `/var/empty`, which holds none — no disk
    /// template, relaunch helper or tool — at host version 1.0 build 1, bundling
    /// ``BundledGuestAgents/testing``.
    package static let testing = AppBundleProducts(
        bundleURL: URL(filePath: "/var/empty/Kernova.app", directoryHint: .isDirectory),
        hostVersion: "1.0", buildNumber: "1", guestAgents: .testing)
}
