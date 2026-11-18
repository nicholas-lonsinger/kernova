import Foundation
import KernovaClipboardItems
import KernovaKit
import KernovaTestSupport
import Testing

/// The one wording both ends log a retraction of their write of the far side's clipboard with.
@Suite("ClipboardRetractionLog", .caseScoped)
struct ClipboardRetractionLogTests {
    private static let endings: [ClipboardItemExchange.RemoteEnding] = [
        .byFarSide, .superseded, .settingChanged, .linkLost,
    ]

    @Test("Only a retraction that took something back logs a line, worded at the guest as at the host, sides swapped")
    func linesAtBothEnds() {
        for ending in Self.endings {
            for retraction: ClipboardRetraction? in [.cleared, .keptPart, .keptEverything, nil] {
                let host = ClipboardRetractionLog.line(retraction, on: .host(vm: "V"), because: ending)
                let guest = ClipboardRetractionLog.line(retraction, on: .guest, because: ending)
                let took = retraction == .cleared || retraction == .keptPart
                let label = "\(ending), \(String(describing: retraction))"
                #expect((host != nil) == took, "\(label)")
                #expect((guest != nil) == took, "\(label)")
                guard let host, let guest else { continue }
                let swapped = host.replacingOccurrences(of: "the guest", with: "the Mac")
                    .replacingOccurrences(of: "host pasteboard for 'V'", with: "guest pasteboard")
                #expect(guest == swapped, "\(label)")
            }
        }
    }

    @Test("Each ending is named by what the host knows of it: the guest's withdrawal says only that it withdrew")
    func causes() {
        func line(_ ending: ClipboardItemExchange.RemoteEnding, _ retraction: ClipboardRetraction = .cleared)
            -> String?
        {
            ClipboardRetractionLog.line(retraction, on: .host(vm: "macOS TEST"), because: ending)
        }
        let cleared = "Retracted the guest's clipboard from the host pasteboard for 'macOS TEST'"
        #expect(line(.byFarSide) == "\(cleared): the guest withdrew its offer")
        #expect(line(.superseded) == "\(cleared): a copy of this side's replaced it")
        #expect(line(.settingChanged) == "\(cleared): the clipboard setting changed")
        #expect(line(.linkLost) == "\(cleared): clipboard sharing with the guest stopped")
        #expect(
            line(.linkLost, .keptPart)
                == "Retracted part of the guest's clipboard from the host pasteboard for 'macOS TEST', the rest kept: clipboard sharing with the guest stopped"
        )
    }
}
