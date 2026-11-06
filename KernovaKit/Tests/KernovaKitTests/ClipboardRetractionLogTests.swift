import KernovaClipboardItems
import KernovaKit
import Testing

/// The one wording both ends log a retraction of their write of the far side's clipboard or copy with.
@Suite("ClipboardRetractionLog")
struct ClipboardRetractionLogTests {
    @Test("The host's lines name the VM and the guest; nothing taken back logs no line")
    func hostLines() {
        func line(_ retraction: ClipboardRetraction?, _ write: ClipboardRetractionLog.Write) -> String? {
            ClipboardRetractionLog.line(
                retraction, of: write, on: .host(vm: "macOS TEST"), because: .passthroughStopped)
        }
        #expect(
            line(.cleared, .clipboard)
                == "Retracted the guest's clipboard from the host pasteboard for 'macOS TEST': passthrough stopped")
        #expect(
            line(.keptPart, .clipboard)
                == "Retracted part of the guest's clipboard from the host pasteboard for 'macOS TEST', the rest kept: passthrough stopped"
        )
        #expect(
            line(.cleared, .copy)
                == "Retracted the guest's copy from the host pasteboard for 'macOS TEST': passthrough stopped")
        #expect(
            line(.keptPart, .copy)
                == "Retracted the guest's copied files from the host pasteboard for 'macOS TEST', the rest of the copy kept: passthrough stopped"
        )
        #expect(line(.keptEverything, .clipboard) == nil)
        #expect(line(.keptEverything, .copy) == nil)
        #expect(line(nil, .clipboard) == nil)
    }

    @Test("Each end names the far side as the cause: its connection, its passthrough, its clipboard, its withdrawal")
    func causes() {
        func line(
            _ end: ClipboardRetractionLog.End, _ write: ClipboardRetractionLog.Write,
            _ ending: ClipboardItemExchange.RemoteEnding
        ) -> String? {
            ClipboardRetractionLog.line(.cleared, of: write, on: end, because: .ended(ending))
        }
        #expect(
            line(.host(vm: "V"), .copy, .linkLost)
                == "Retracted the guest's copy from the host pasteboard for 'V': the guest's connection ended")
        #expect(
            line(.host(vm: "V"), .clipboard, .passthroughStopped)
                == "Retracted the guest's clipboard from the host pasteboard for 'V': the guest stopped passthrough")
        #expect(
            line(.host(vm: "V"), .clipboard, .byFarSide(hasSuccessor: false))
                == "Retracted the guest's clipboard from the host pasteboard for 'V': the guest's clipboard moved on")
        #expect(
            line(.guest, .clipboard, .linkLost)
                == "Retracted the Mac's clipboard from the guest pasteboard: the Mac's connection ended")
        #expect(
            line(.guest, .clipboard, .passthroughStopped)
                == "Retracted the Mac's clipboard from the guest pasteboard: the Mac stopped passthrough")
        #expect(
            line(.guest, .copy, .byFarSide(hasSuccessor: false))
                == "Retracted the Mac's copy from the guest pasteboard: the Mac withdrew the copy")
    }
}
