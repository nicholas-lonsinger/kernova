import Foundation
import KernovaKit

/// The two clipboard commands: each copies a snapshot of one side's clipboard to the other's, everything on it
/// as it is. What is not a file or folder crosses at the command and lands as data; files cross as references
/// to the source's disk and transfer when pasted, served until the destination's clipboard lets them go or the
/// connection ends. A destination that changed after the command is left as it is. Every outcome short of
/// that goes to the VM's transfer report, which the status item shows.
extension VMInstance {
    /// Copies the Mac's clipboard as it stands now to the guest's. A Mac clipboard that is this VM's write of
    /// the guest's own offer is the guest's clipboard already, so nothing is copied.
    package func copyMacClipboardToGuest() {
        guard let service = clipboardService, service.isConnected, begin(.copyMacClipboardToGuest) else { return }
        let pasteboard = hostClipboardPublisher.pasteboard
        clipboardTransfers.gestureBegan()
        Task { @MainActor [weak self, weak service] in
            defer { self?.runningClipboardCommands.remove(.copyMacClipboardToGuest) }
            let outcome = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, destinationOffer: service?.guestOfferToken,
                ceiling: self?.effectiveClipboardMaxPasteBytes ?? ClipboardPasteLimit.defaultBytes,
                promiseDestination: {
                    guard let destination = service?.reservePromiseDestination() else {
                        throw ClipboardServeError.unavailable
                    }
                    return destination
                })
            guard let self, let service else { return }
            switch outcome {
            case .nothing:
                reportClipboardCommand(.send, .nothingToCopy)
            case .changed:
                reportClipboardCommand(.send, .transferFailed)
            case .heldByDestination:
                break
            case .tooLarge(let limitBytes):
                reportClipboardCommand(.send, .tooLarge(limitBytes: limitBytes))
            case .snapshot(let snapshot, let lost):
                if let failure = service.copyMacClipboardToGuest(snapshot) {
                    reportClipboardCommand(.send, failure)
                } else if lost > 0, service.supportsBinaryRepresentations {
                    reportClipboardCommand(.send, .itemsSkipped(count: lost))
                }
            }
        }
    }

    /// Copies the guest's clipboard as it stands now to the Mac's, unless the Mac's changes before it lands, by
    /// anything but this VM's own write. A file set over the paste ceiling is left off, and said so; with nothing
    /// else to copy, nothing is written. A guest clipboard that is its write of this
    /// VM's own offer is the Mac's clipboard already, so nothing is copied.
    package func copyGuestClipboardToMac() {
        guard let service = clipboardService, service.isConnected, begin(.copyGuestClipboardToMac) else { return }
        let publisher = hostClipboardPublisher
        let commandedAt = publisher.pasteboard.changeCount
        clipboardTransfers.gestureBegan()
        Task { @MainActor [weak self, weak service] in
            defer { self?.runningClipboardCommands.remove(.copyGuestClipboardToMac) }
            guard let copy = await service?.guestClipboardCopy() else { return }
            guard let self else {
                if case .copy(let contents) = copy { contents.release() }
                return
            }
            switch copy {
            case .nothing:
                reportClipboardCommand(.copy, .nothingToCopy)
            case .alreadyHeld:
                break
            case .failed(let failure):
                reportClipboardCommand(.copy, failure)
            case .copy(let contents):
                let changeCount = publisher.pasteboard.changeCount
                guard changeCount == commandedAt || changeCount == publisher.lastWriteChangeCount else {
                    contents.release()
                    return reportClipboardCommand(.copy, .clipboardChanged)
                }
                let ceiling = effectiveClipboardMaxPasteBytes
                guard contents.plan != .tooLarge else {
                    contents.release()
                    return reportClipboardCommand(.copy, .tooLarge(limitBytes: ceiling))
                }
                guard publisher.writeCopy(contents, servingFileURLs: contents.plan.servesFileURLs) else {
                    return reportClipboardCommand(.copy, .transferFailed)
                }
                if case .withoutFiles(let count) = contents.plan {
                    reportClipboardCommand(.copy, .filesLeftOut(count: count, limitBytes: ceiling))
                }
            }
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
