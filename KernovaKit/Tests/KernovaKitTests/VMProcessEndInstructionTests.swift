import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCommandModel

/// The Terminal command a pending Force Stop hands the user, which they paste
/// into a shell: the bundle path in it must reach `lsof` as one word, whatever
/// it holds.
@Suite("VM Process End Instruction Tests", .caseScoped)
struct VMProcessEndInstructionTests {
    @Test("The command names the bundle as one shell word, whatever characters its path holds")
    func commandQuotesThePath() {
        let rows: [(path: String, command: String)] = [
            (
                "/Users/pbear/Library/VMs/1D2C.kernova",
                "kill -9 $(lsof -t -c com.apple.Virtualization -a +D '/Users/pbear/Library/VMs/1D2C.kernova')"
            ),
            (
                "/Volumes/Fast Disk/VMs/1D2C.kernova",
                "kill -9 $(lsof -t -c com.apple.Virtualization -a +D '/Volumes/Fast Disk/VMs/1D2C.kernova')"
            ),
            (
                "/Users/o'brien/VMs/1D2C.kernova",
                #"kill -9 $(lsof -t -c com.apple.Virtualization -a +D '/Users/o'\''brien/VMs/1D2C.kernova')"#
            ),
            (
                "/tmp/$HOME `id` \"x\"/1D2C.kernova",
                #"kill -9 $(lsof -t -c com.apple.Virtualization -a +D '/tmp/$HOME `id` "x"/1D2C.kernova')"#
            ),
        ]
        for row in rows {
            #expect(VMProcessEndInstruction.command(endingProcessOfBundleAt: row.path) == row.command)
        }
    }

    @Test("A timeout on a Force Stop still pending tells the user how to end the process, not to force stop")
    func timedOutForceStopMessage() {
        let vm = VMSummary(
            id: UUID(), name: "Alpha", status: "forceStopping", ipAddress: .unavailable,
            heldByAnotherCopy: false)
        let failure = CommandErrorDTO.timedOut(
            vm: vm, verb: .stop, seconds: 5,
            processEnd: VMProcessEndInstruction(appName: "Kernova", bundlePath: "/VMs/1D2C.kernova"))
        #expect(
            failure.message
                == "\u{201C}Alpha\u{201D} did not power off within 5 seconds. Kernova is waiting for this "
                + "virtual machine\u{2019}s process to end and can\u{2019}t end it itself. If it doesn\u{2019}t "
                + "end, run this command in Terminal:\n"
                + "  kill -9 $(lsof -t -c com.apple.Virtualization -a +D '/VMs/1D2C.kernova')")
    }
}
