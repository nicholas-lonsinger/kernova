import Foundation
import KernovaKit

/// The two clipboard commands: each copies a snapshot of one side's clipboard to the other's, everything on it
/// as it is. What is not a file or folder crosses at the command and lands as data; files cross as references
/// to the source's disk and transfer when pasted, served until the destination's clipboard moves on or the
/// connection ends. A concealed copy stays on the destination only while the source's clipboard still holds it
/// and the connection is up. A destination that changed after the command is left as it is. Every outcome short
/// of that goes to the VM's transfer report, which the status item shows.
extension VMInstance {
    /// Copies the Mac's clipboard as it stands now to the guest's. What the Mac holds only as this guest's
    /// promise goes by reference, which the guest fills from its own offer; another VM's is pulled now.
    package func copyMacClipboardToGuest() {
        guard let service = clipboardService, service.isConnected, begin(.copyMacClipboardToGuest) else { return }
        let pasteboard = hostClipboardPublisher.pasteboard
        clipboardTransfers.gestureBegan()
        Task { @MainActor [weak self, weak service] in
            defer { self?.runningClipboardCommands.remove(.copyMacClipboardToGuest) }
            guard let staging = service?.snapshotStaging, let connection = service?.clipboardConnection else { return }
            let outcome = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard,
                ceiling: self?.effectiveClipboardMaxPasteBytes ?? ClipboardPasteLimit.defaultBytes,
                staging: staging, copyingTo: connection)
            guard let self, let service else { return }
            switch outcome {
            case .nothing:
                reportClipboardCommand(.send, .nothingToCopy)
            case .unreadable:
                reportClipboardCommand(.send, .itemsUnreadable)
            case .changed:
                reportClipboardCommand(.send, .transferFailed)
            case .tooLarge(let limitBytes):
                reportClipboardCommand(.send, .tooLarge(limitBytes: limitBytes))
            case .snapshot(let snapshot, let lost):
                if let failure = service.copyMacClipboardToGuest(snapshot) {
                    reportClipboardCommand(.send, failure)
                } else if lost > 0 {
                    reportClipboardCommand(.send, .itemsSkipped(count: lost))
                }
            }
        }
    }

    /// Copies the guest's clipboard as it stands now to the Mac's, unless the Mac's changes before it lands. A file set over the paste ceiling is left off, and said so; with nothing
    /// else to copy, nothing is written. What the guest holds only as this VM's
    /// promise comes by reference, filled from what this VM sent; a copy naming
    /// only what the Mac's clipboard still holds changes nothing.
    package func copyGuestClipboardToMac() {
        guard let service = clipboardService, service.isConnected, begin(.copyGuestClipboardToMac) else { return }
        let publisher = hostClipboardPublisher
        let commandedAt = publisher.pasteboard.changeCount
        clipboardTransfers.gestureBegan()
        Task { @MainActor [weak self, weak service] in
            defer { self?.runningClipboardCommands.remove(.copyGuestClipboardToMac) }
            let copy = await service?.guestClipboardCopy { [weak self] contents in
                guard let self else { return contents.release() }
                self.writeGuestCopy(contents, commandedAt: commandedAt)
            }
            guard let self, let copy else { return }
            switch copy {
            case .nothing:
                reportClipboardCommand(.copy, .nothingToCopy)
            case .alreadyHeld, .landed:
                break
            case .failed(let failure):
                reportClipboardCommand(.copy, failure)
            }
        }
    }

    /// Writes the guest's landed copy `contents` to the Mac, unless the Mac's clipboard changed since
    /// `commandedAt`.
    private func writeGuestCopy(_ contents: GuestCopyContents, commandedAt: Int) {
        let publisher = hostClipboardPublisher
        guard publisher.pasteboard.changeCount == commandedAt else {
            contents.release()
            return reportClipboardCommand(.copy, .clipboardChanged)
        }
        let ceiling = effectiveClipboardMaxPasteBytes
        guard contents.plan != .tooLarge else {
            contents.release()
            return reportClipboardCommand(.copy, .tooLarge(limitBytes: ceiling))
        }
        guard publisher.writeCopy(contents, servingFileURLs: contents.plan.servesFileURLs) else {
            return reportClipboardCommand(.copy, contents.referencesLeftOut > 0 ? .partsGone : .transferFailed)
        }
        if case .withoutFiles(let count) = contents.plan {
            reportClipboardCommand(.copy, .filesLeftOut(count: count, limitBytes: ceiling))
        } else if contents.referencesLeftOut > 0 {
            reportClipboardCommand(.copy, .partsGone)
        } else if contents.itemsLeftOut > 0 {
            reportClipboardCommand(.copy, .itemsSkipped(count: contents.itemsLeftOut))
        }
    }

    /// Starts `command` unless it is running already, returning whether it started.
    private func begin(_ command: ClipboardCommand) -> Bool {
        runningClipboardCommands.insert(command).inserted
    }

    private func reportClipboardCommand(_ gesture: ClipboardTransferGesture, _ failure: ClipboardTransferFailure) {
        clipboardTransfers.finish(ClipboardTransferFinish(gesture: gesture, outcome: .failed(failure), peerName: name))
    }
}

/// One of the clipboard commands.
package enum ClipboardCommand: Hashable, Sendable {
    case copyGuestClipboardToMac
    case copyMacClipboardToGuest
}
