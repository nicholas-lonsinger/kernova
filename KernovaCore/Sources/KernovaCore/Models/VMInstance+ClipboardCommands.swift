import Foundation
import KernovaKit

/// The two clipboard commands: each copies a snapshot of one side's clipboard to the other's, everything on it
/// as it is. What is not a file or folder crosses at the command and lands as data; files cross as references
/// to the source's disk and transfer when pasted, served until the destination's clipboard lets them go or the
/// connection ends. A destination that changed after the command is left as it is. Every outcome short of
/// that goes to the VM's transfer report, which the status item shows.
extension VMInstance {
    /// Copies the Mac's clipboard as it stands now to the guest's. A clipboard that changed while it was read is
    /// read once more.
    package func copyMacClipboardToGuest() {
        guard let service = clipboardService, service.isConnected else { return }
        let pasteboard = hostClipboardPublisher.pasteboard
        let promises = pasteboard.filePromiseReceivers
        clipboardTransfers.gestureBegan()
        Task { @MainActor [weak self, weak service] in
            var outcome = ClipboardPasteboardReader.SnapshotOutcome.changed
            for _ in 0..<2 {
                outcome = await ClipboardPasteboardReader.readSnapshot(
                    from: pasteboard, promises: promises,
                    promiseDestination: {
                        guard let destination = service?.reservePromiseDestination() else {
                            throw ClipboardServeError.unavailable
                        }
                        return destination
                    })
                if case .changed = outcome { continue }
                break
            }
            guard let self, let service else { return }
            switch outcome {
            case .nothing:
                reportClipboardCommand(.send, .nothingToCopy)
            case .changed:
                reportClipboardCommand(.send, .transferFailed)
            case .snapshot(let snapshot, let lost):
                if let failure = service.copyMacClipboardToGuest(snapshot) {
                    reportClipboardCommand(.send, failure)
                } else if lost > 0, service.supportsBinaryRepresentations {
                    reportClipboardCommand(.send, .itemsSkipped(count: lost))
                }
            }
        }
    }

    /// Copies the guest's clipboard as it stands now to the Mac's, unless the Mac's changes before it lands. A
    /// file set over the paste ceiling is left off, and said so.
    package func copyGuestClipboardToMac() {
        guard let service = clipboardService, service.isConnected else { return }
        let publisher = hostClipboardPublisher
        let commandedAt = publisher.pasteboard.changeCount
        clipboardTransfers.gestureBegan()
        Task { @MainActor [weak self, weak service] in
            guard let copy = await service?.guestClipboardCopy() else { return }
            guard let self else {
                if case .copy(let contents) = copy { contents.release() }
                return
            }
            switch copy {
            case .nothing:
                reportClipboardCommand(.copy, .nothingToCopy)
            case .failed(let failure):
                reportClipboardCommand(.copy, failure)
            case .copy(let contents):
                guard publisher.pasteboard.changeCount == commandedAt else {
                    contents.release()
                    return reportClipboardCommand(.copy, .clipboardChanged)
                }
                let ceiling = effectiveClipboardMaxPasteBytes
                let budget = ClipboardPromisePolicy.pasteBudget(contents.items, limit: ceiling)
                guard publisher.writeCopy(contents, servingFileURLs: !budget.exceeds) else {
                    return reportClipboardCommand(.copy, .transferFailed)
                }
                // The Mac's clipboard is the guest's copy now, so an offer of what it held before is stale.
                service?.hostCopyOffersNothing()
                if budget.exceeds { reportClipboardCommand(.copy, .tooLarge(limitBytes: ceiling)) }
            }
        }
    }

    private func reportClipboardCommand(_ gesture: ClipboardTransferGesture, _ failure: ClipboardTransferFailure) {
        clipboardTransfers.finish(ClipboardTransferFinish(gesture: gesture, outcome: .failed(failure), peerName: name))
    }
}
