import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for the classification every pull of a peer offer lands on when it
/// aborts — the paste-time blocking fire and the lazy preview pull alike.
@Suite("ClipboardTransferFailure.inboundPullAborted")
struct ClipboardTransferFailureTests {
    private func abortInfo(
        _ code: ClipboardStreamAbortCode, needed: Int? = nil, available: Int? = nil
    ) -> ClipboardStreamAbortInfo {
        ClipboardStreamAbortInfo(
            transferID: 1, code: code, message: "aborted", neededBytes: needed,
            availableBytes: available)
    }

    @Test(
        "an abort that retires the transfer classifies to no failure",
        arguments: Array(ClipboardStreamAbortCode.retiring))
    func retiringAbortsClassifyToNothing(code: ClipboardStreamAbortCode) {
        #expect(ClipboardTransferFailure.inboundPullAborted(abortInfo(code)) == nil)
    }

    /// Runs over `allCases` and spells every one of them, with no `default:`, so
    /// a code added to `ClipboardStreamAbortCode` fails to compile here until
    /// someone states what it classifies to. The implementation's own `default:`
    /// keeps an unstated code reported rather than swallowed; this is what makes
    /// falling into it a decision rather than an oversight.
    @Test(
        "every abort that is not a retirement classifies to a reportable failure",
        arguments: ClipboardStreamAbortCode.allCases.filter {
            !ClipboardStreamAbortCode.retiring.contains($0)
        })
    func failedAbortsClassifyToAFailure(code: ClipboardStreamAbortCode) {
        let failure = ClipboardTransferFailure.inboundPullAborted(abortInfo(code))
        switch code {
        case .diskFull:
            guard case .diskFull = failure else {
                Issue.record("\(code.rawValue) should report the disk, got \(String(describing: failure))")
                return
            }
        case .extractError:
            #expect(failure == .unpackFailed)
        case .requestRange, .requestUTI, .requestCancelled, .readError, .sendFailed,
            .sizeOverrun, .sizeMismatch, .digestMismatch, .payloadUnsupported, .payloadInvalid,
            .writeError, .stageError, .mapError, .stallTimeout, .pasteTimeout:
            #expect(failure == .transferFailed)
        case .cancelled, .superseded, .requestStale, .userCancelled:
            Issue.record("\(code.rawValue) retires the transfer and is covered by the case above")
        }
    }

    @Test("a disk-full abort carries whichever figures it knew")
    func diskFullCarriesItsNumbers() {
        #expect(
            ClipboardTransferFailure.inboundPullAborted(abortInfo(.diskFull, needed: 4096, available: 1024))
                == .diskFull(needed: 4096, available: 1024))
        #expect(
            ClipboardTransferFailure.inboundPullAborted(abortInfo(.diskFull))
                == .diskFull(needed: nil, available: nil))
    }

    @Test("only a refusal of a gesture made here interrupts on this side")
    func onlyPeerPasteIsTheirsToReport() {
        for gesture in [
            ClipboardTransferGesture.paste, .preview, .copy, .forward, .drop,
        ] {
            #expect(gesture.isMadeHere, "\(gesture) refuses a gesture made on this side")
        }
        // The guest user's own paste refusal — their agent's dropdown reveals it
        // over there (docs/CLIPBOARD.md §13).
        #expect(!ClipboardTransferGesture.peerPaste.isMadeHere)
    }
}
