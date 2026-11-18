import KernovaClipboardItems
import KernovaKit
import KernovaTestSupport
import Testing

/// The one wording both ends log a retraction of their write of the far side's clipboard with.
@Suite("ClipboardRetractionLog", .caseScoped)
struct ClipboardRetractionLogTests {
    @Test("The host's lines name the VM and the guest; nothing taken back logs no line")
    func hostLines() {
        func line(_ retraction: ClipboardRetraction?) -> String? {
            ClipboardRetractionLog.line(retraction, on: .host(vm: "macOS TEST"), because: .settingChanged)
        }
        #expect(
            line(.cleared)
                == "Retracted the guest's clipboard from the host pasteboard for 'macOS TEST': the clipboard setting changed"
        )
        #expect(
            line(.keptPart)
                == "Retracted part of the guest's clipboard from the host pasteboard for 'macOS TEST', the rest kept: the clipboard setting changed"
        )
        #expect(line(.keptEverything) == nil)
        #expect(line(nil) == nil)
    }

    @Test("Each end names the cause: sharing with the far side, the setting, the far side's clipboard")
    func causes() {
        func line(_ end: ClipboardRetractionLog.End, _ ending: ClipboardItemExchange.RemoteEnding) -> String? {
            ClipboardRetractionLog.line(.cleared, on: end, because: ending)
        }
        #expect(
            line(.host(vm: "V"), .linkLost)
                == "Retracted the guest's clipboard from the host pasteboard for 'V': clipboard sharing with the guest stopped"
        )
        #expect(
            line(.host(vm: "V"), .settingChanged)
                == "Retracted the guest's clipboard from the host pasteboard for 'V': the clipboard setting changed")
        #expect(
            line(.host(vm: "V"), .byFarSide)
                == "Retracted the guest's clipboard from the host pasteboard for 'V': the guest's clipboard moved on")
        #expect(
            line(.guest, .linkLost)
                == "Retracted the Mac's clipboard from the guest pasteboard: clipboard sharing with the Mac stopped")
        #expect(
            line(.guest, .settingChanged)
                == "Retracted the Mac's clipboard from the guest pasteboard: the clipboard setting changed")
        #expect(
            line(.guest, .byFarSide)
                == "Retracted the Mac's clipboard from the guest pasteboard: the Mac's clipboard moved on")
    }
}
