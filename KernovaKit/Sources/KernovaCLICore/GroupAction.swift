import ArgumentParser
import Foundation
import KernovaKit

extension GroupTargetOptions {
    /// The group a lifecycle verb acts on, `nil` when it names a virtual
    /// machine instead.
    var target: VMGroupReference? { groups.first }

    /// Refuses a lifecycle line naming both a virtual machine and a group, or
    /// neither — and one naming a group beside any of `singleVMFlags`, the
    /// flags given that change only one virtual machine's verb.
    func validateTarget(vm: String?, singleVMFlags: [String]) throws {
        switch (vm, target) {
        case (nil, nil):
            throw ValidationError(
                "Name a virtual machine, or a group with --smart-group or --folder.")
        case (.some, .some):
            throw ValidationError("Name a virtual machine or a group, not both.")
        case (nil, .some):
            if let flag = singleVMFlags.first {
                throw ValidationError("\(flag) acts on one virtual machine, not a group.")
            }
        case (.some, nil):
            break
        }
    }
}

/// What a lifecycle verb given a group prints, and what it exits with.
enum GroupActionOutput {
    /// One line per virtual machine in the group — what the action did to it,
    /// or why it did not — or the report itself as JSON.
    ///
    /// `quiet` prints the names of the virtual machines the action was done
    /// to, which a shell loop feeds to the next command.
    static func render(_ report: VMGroupActionReport, format: OutputFormat, quiet: Bool) throws -> String {
        switch format {
        case .json:
            return try JSONRenderer.render(report)
        case .table:
            guard !quiet else {
                return report.results.filter {
                    if case .done = $0.outcome { true } else { false }
                }.map(\.vm.name).joined(separator: "\n")
            }
            return report.results.map { $0.line(for: report.action) }.joined(separator: "\n")
        }
    }

    /// The exit a report owes: ``CLIExitCode/groupIncomplete`` when the action
    /// left a virtual machine it concerned undone, `nil` when it left none.
    static func failure(_ report: VMGroupActionReport) -> CLIFailure? {
        let undone = report.undone.count
        guard undone > 0 else { return nil }
        let of = undone == 1 ? "1 virtual machine" : "\(undone) virtual machines"
        return CLIFailure(
            .groupIncomplete,
            "Couldn\u{2019}t \(report.action.rawValue) \(of) in \u{201C}\(report.groupName)\u{201D}.")
    }
}

extension VerbCommand {
    /// Sends a group action, prints what it did to each virtual machine, and
    /// exits as ``GroupActionOutput/failure(_:)`` says.
    func performGroupAction() throws {
        let answered = try answer()
        guard case .groupAction(let report) = answered else { throw answered.unexpectedAnswer }
        Console.out(try GroupActionOutput.render(report, format: options.format, quiet: options.quiet))
        if let failure = GroupActionOutput.failure(report) { throw failure }
    }
}
