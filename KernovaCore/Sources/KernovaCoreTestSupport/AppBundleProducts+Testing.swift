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
    package static let none = BundledGuestAgents(entries: [:], macOSInstallerDiskImageURL: nil, linuxDisk: .testing)

    /// The entries of one payload file at `url` serving both scopes of `os` on arm64, updating in band.
    private static func entries(
        _ os: OSFamily, _ format: PayloadFormat, at url: URL, versionLabel: String
    ) -> [BundledGuestAgentKey: BundledGuestAgentEntry] {
        var entries: [BundledGuestAgentKey: BundledGuestAgentEntry] = [:]
        for scope in [InstallScope.user, .system] {
            entries[BundledGuestAgentKey(os, .arm64, scope)] = BundledGuestAgentEntry(
                fileURL: url, format: format, versionLabel: versionLabel, updatesInBand: true)
        }
        return entries
    }

    /// Only a Linux agent, the file at `agent`, whose disk `disk` writes.
    package static func linux(agent: URL, disk: GuestAgentDiskCache, versionLabel: String = "1.0 (1)")
        -> BundledGuestAgents
    {
        BundledGuestAgents(
            entries: entries(.linux, .executable, at: agent, versionLabel: versionLabel),
            macOSInstallerDiskImageURL: nil, linuxDisk: disk)
    }

    /// A macOS agent labelled `1.0 (1)`, as ``AppBundleProducts/testing`` labels its build, whose payload and
    /// installer image stand in as a small file every Mac holds: the core only reads them, hashing the
    /// payload and copying the image into a VM's bundle when the disk is attached. No Linux agent.
    package static let testing = macOS(
        versionLabel: "1.0 (1)",
        installerDiskImageURL: URL(filePath: "/System/Library/CoreServices/SystemVersion.plist"))

    /// Only a macOS agent labelled `versionLabel` with its installer at `installerDiskImageURL`, or no
    /// agent at all when that is `nil`; the installer image stands in as the payload too.
    package static func macOS(versionLabel: String, installerDiskImageURL: URL?) -> BundledGuestAgents {
        BundledGuestAgents(
            entries: installerDiskImageURL.map {
                entries(.macOS, .containerTree, at: $0, versionLabel: versionLabel)
            } ?? [:],
            macOSInstallerDiskImageURL: installerDiskImageURL, linuxDisk: .testing)
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
