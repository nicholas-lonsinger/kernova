import Foundation
import KernovaCommandModel

/// The save of a live VM a question about its USB disks is asked for.
package enum USBSaveAction: Sendable, Equatable {
    case suspend
    case takeSnapshot
    case clone
    /// The quit's suspend of every live VM, asked once for all of them.
    case quit
}

/// One USB disk a save of a live VM unplugs, by the name Kernova shows it
/// under — the guest exposes nothing that maps back to a VZ device.
package struct USBSaveDisk: Sendable, Equatable {
    package let name: String
    /// Whether the guest can write to it: a removable medium not attached
    /// read-only, or a passed-through drive, which Kernova cannot tell.
    package let writable: Bool

    package init(name: String, writable: Bool) {
        self.name = name
        self.writable = writable
    }
}

/// What a save of one live VM is decided from.
package struct USBSaveFacts: Sendable, Equatable {
    package let vmName: String
    /// Every disk the save unplugs; empty for a VM with no live session.
    package let disks: [USBSaveDisk]
    /// Whether the guest is paused, which keeps it from ejecting anything.
    package let isPaused: Bool
    /// Whether the guest's agent can eject the disks before they are unplugged.
    package let agentEjects: Bool

    package init(vmName: String, disks: [USBSaveDisk], isPaused: Bool, agentEjects: Bool) {
        self.vmName = vmName
        self.disks = disks
        self.isPaused = isPaused
        self.agentEjects = agentEjects
    }

    /// The facts of `instance` as it stands: its removable media by their
    /// labels, and each passed-through accessory that declares mass storage.
    /// Another accessory comes off the guest too, and goes unnamed.
    ///
    /// No guest agent ejects a disk yet, so every writable disk is at risk.
    @MainActor
    init(_ instance: VMInstance) {
        let configured = Dictionary(
            (instance.configuration.removableMedia ?? []).map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first })
        let media = instance.liveRemovableMedia.map {
            USBSaveDisk(name: configured[$0.id] ?? $0.displayName, writable: !$0.readOnly)
        }
        let drives = instance.liveUSBAccessories.filter(\.accessory.isMassStorage).map {
            USBSaveDisk(name: $0.accessory.displayName, writable: true)
        }
        self.init(
            vmName: instance.name, disks: media + drives, isPaused: instance.isLivePaused,
            agentEjects: false)
    }
}

/// Why a writable disk may lose changes when a save unplugs it.
package enum USBDiskRisk: Sendable, Equatable {
    /// A paused guest runs nothing that could eject it.
    case paused
    /// Nothing in the guest can eject it.
    case noAgent
}

/// A writable disk a save would unplug without the guest having ejected it.
package struct USBDiskAtRisk: Sendable, Equatable {
    package let disk: USBSaveDisk
    package let risk: USBDiskRisk

    package init(disk: USBSaveDisk, risk: USBDiskRisk) {
        self.disk = disk
        self.risk = risk
    }
}

/// What a save of one live VM asks before it unplugs the USB disks the VM
/// holds: nothing, the reminder that it unplugs them, or the warning that a
/// disk may lose changes.
///
/// Every save of a live guest unplugs every hot-pluggable USB device first
/// (``VMLiveStateCapture``), so no saved state holds one and no restore lists
/// one. The reminder is ``ConfirmationKind/unplugUSBDisks``, which every
/// automation door and a user who turned it off give up front; the warning is
/// ``ConfirmationKind/unplugUSBDisksAtRisk``, which implies the reminder.
package enum USBSaveDecision: Sendable, Equatable {
    case proceed
    /// Ask the reminder, naming every disk.
    case remind([USBSaveDisk])
    /// Ask the warning, naming only the disks at risk.
    case warn([USBDiskAtRisk])

    /// The decision for a save of the VM `facts` describe under `consent`.
    package static func decide(_ facts: USBSaveFacts, consent: Consent) -> USBSaveDecision {
        guard !facts.disks.isEmpty else { return .proceed }
        let canEject = !facts.isPaused && facts.agentEjects
        let atRisk = facts.disks.filter { $0.writable && !canEject }.map {
            USBDiskAtRisk(disk: $0, risk: facts.isPaused ? .paused : .noAgent)
        }
        if !atRisk.isEmpty {
            return consent.covers(.unplugUSBDisksAtRisk) ? .proceed : .warn(atRisk)
        }
        let reminded = consent.covers(.unplugUSBDisks) || consent.covers(.unplugUSBDisksAtRisk)
        return reminded ? .proceed : .remind(facts.disks)
    }

    /// Throws the question a save of `instance` as `action` asks under
    /// `consent`, decided from the VM as it stands — nothing for a VM with no
    /// live session, whose save unplugs nothing.
    @MainActor
    static func require(_ consent: Consent, toSave instance: VMInstance, as action: USBSaveAction) throws {
        let facts = USBSaveFacts(instance)
        guard
            let prompt = USBSavePrompt.prompt(
                for: [(facts.vmName, decide(facts, consent: consent))], action: action)
        else { return }
        throw CommandError.confirmationRequired(prompt)
    }
}

/// The words a USB question is asked in, for one VM or — at a quit — several.
package enum USBSavePrompt {
    /// The one question `decisions` ask for `action`: the warning when any VM
    /// has a disk at risk, listing only those; otherwise the reminder, listing
    /// every disk; `nil` when every VM proceeds.
    package static func prompt(
        for decisions: [(vmName: String, decision: USBSaveDecision)], action: USBSaveAction
    ) -> ConfirmationPrompt? {
        let vmNames = decisions.map(\.vmName)
        let named = decisions.count > 1 || action == .quit
        let atRisk = decisions.flatMap { vm, decision -> [(String, USBDiskAtRisk)] in
            guard case .warn(let disks) = decision else { return [] }
            return disks.map { (vm, $0) }
        }
        if !atRisk.isEmpty {
            return warning(atRisk, from: vmNames, naming: named, action: action)
        }
        let reminded = decisions.flatMap { vm, decision -> [(String, USBSaveDisk)] in
            guard case .remind(let disks) = decision else { return [] }
            return disks.map { (vm, $0) }
        }
        guard !reminded.isEmpty else { return nil }
        return reminder(reminded, naming: named, action: action)
    }

    private static func reminder(
        _ disks: [(vm: String, disk: USBSaveDisk)], naming named: Bool, action: USBSaveAction
    ) -> ConfirmationPrompt {
        let them = disks.count == 1 ? "it" : "them"
        let unplugged =
            named
            ? list(disks.map { "\(quoted($0.disk.name)) from \(quoted($0.vm))" })
            : "\(list(disks.map { quoted($0.disk.name) })) from \(quoted(disks[0].vm))"
        return ConfirmationPrompt(
            kind: .unplugUSBDisks,
            title: "\(action.gerund) unplugs USB disks",
            message:
                "Kernova unplugs \(unplugged) before it \(action.verbPhrase), and plugs \(them) back in \(action.replugPhrase).",
            confirmTitle: action.confirmTitle,
            confirmIsDestructive: false,
            dismissTitle: "Cancel",
            offersSuppression: true)
    }

    private static func warning(
        _ disks: [(vm: String, disk: USBDiskAtRisk)], from vmNames: [String], naming named: Bool,
        action: USBSaveAction
    ) -> ConfirmationPrompt {
        let lines = disks.map { vm, atRisk in
            let name = named ? "\(quoted(atRisk.disk.name)) from \(quoted(vm))" : quoted(atRisk.disk.name)
            return "\(name) may lose changes: \(atRisk.risk.reason)."
        }
        return ConfirmationPrompt(
            kind: .unplugUSBDisksAtRisk,
            title: "\(list(disks.map { quoted($0.disk.disk.name) })) may lose changes",
            message:
                "Kernova unplugs USB disks from \(list(vmNames.map(quoted))) before it \(action.verbPhrase).\n\n"
                + lines.joined(separator: "\n"),
            confirmTitle: "\(action.confirmTitle) Anyway",
            confirmIsDestructive: true,
            dismissTitle: "Cancel")
    }

    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }

    private static func list(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }
}

extension USBDiskRisk {
    /// Why the disk is at risk, as the clause after its name.
    fileprivate var reason: String {
        switch self {
        case .paused: "the guest can\u{2019}t eject it while the virtual machine is paused"
        case .noAgent: "without the guest agent, Kernova can\u{2019}t eject it"
        }
    }
}

extension USBSaveAction {
    fileprivate var gerund: String {
        switch self {
        case .suspend: "Suspending"
        case .takeSnapshot: "Taking a snapshot"
        case .clone: "Cloning"
        case .quit: "Quitting"
        }
    }

    fileprivate var verbPhrase: String {
        switch self {
        case .suspend: "suspends"
        case .takeSnapshot: "takes the snapshot"
        case .clone: "copies the virtual machine"
        case .quit: "quits"
        }
    }

    fileprivate var replugPhrase: String {
        switch self {
        case .suspend, .quit: "when you resume"
        case .takeSnapshot: "once the snapshot is taken"
        case .clone: "once the copy is made"
        }
    }

    fileprivate var confirmTitle: String {
        switch self {
        case .suspend: "Suspend"
        case .takeSnapshot: "Take Snapshot"
        case .clone: "Clone"
        case .quit: "Quit"
        }
    }
}
