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

    @Test("A refusal carrying the instruction tells the user its command, and a timeout drops its own advice for it")
    func refusalsCarryTheInstruction() {
        let vm = VMSummary(
            id: UUID(), name: "Alpha", status: "forceStopping", ipAddress: .unavailable,
            heldByAnotherCopy: false)
        let instruction = VMProcessEndInstruction(appName: "Kernova", bundlePath: "/VMs/1D2C.kernova")
        let pairs: [(carrying: CommandErrorDTO, plain: CommandErrorDTO)] = [
            (
                .timedOut(vm: vm, verb: .stop, seconds: 5, processEnd: instruction),
                .timedOut(vm: vm, verb: .stop, seconds: 5)
            ),
            (
                .busy(vm: vm, operation: "force stopping", processEnd: instruction),
                .busy(vm: vm, operation: "force stopping")
            ),
            (
                .invalidState(vm: vm, current: "forceStopping", allowed: [], processEnd: instruction),
                .invalidState(vm: vm, current: "forceStopping", allowed: [])
            ),
        ]
        for (carrying, plain) in pairs {
            #expect(carrying.message.contains(instruction.command), "\(carrying)")
            #expect(!plain.message.contains(instruction.command), "\(plain)")
        }
        // A timeout's own advice is to force stop, which is what the
        // instruction says is already under way.
        let plainTimeout = pairs[0].plain.message
        let advice = plainTimeout.drop(while: { $0 != "." }).dropFirst(2)
        #expect(!advice.isEmpty)
        #expect(!pairs[0].carrying.message.contains(advice))
    }
}
