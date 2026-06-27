import Testing

@testable import Kernova

@Suite("ClipboardTransferProgress")
struct ClipboardTransferProgressTests {
    @Test("a zero total reads as 0, never a divide-by-zero")
    func zeroTotal() {
        let progress = ClipboardTransferProgress(
            direction: .outbound, bytesTransferred: 0, totalBytes: 0, label: nil)
        #expect(progress.fractionComplete == 0)
    }

    @Test("a partial transfer is the byte ratio")
    func partial() {
        let progress = ClipboardTransferProgress(
            direction: .inbound, bytesTransferred: 50, totalBytes: 200, label: nil)
        #expect(progress.fractionComplete == 0.25)
    }

    @Test("transferred beyond total clamps to 1")
    func overshoot() {
        let progress = ClipboardTransferProgress(
            direction: .outbound, bytesTransferred: 300, totalBytes: 200, label: nil)
        #expect(progress.fractionComplete == 1)
    }

    @Test("negative bytes clamp to 0")
    func negative() {
        let progress = ClipboardTransferProgress(
            direction: .outbound, bytesTransferred: -10, totalBytes: 200, label: nil)
        #expect(progress.fractionComplete == 0)
    }
}
