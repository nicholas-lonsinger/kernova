import Foundation
import KernovaKit
import KernovaLogging

/// A group header's Start All, Suspend All and Stop All.
extension VMLibraryViewModel {
    /// How many of the VMs in `group` each action acts on now, `nil` when the
    /// library's groups cannot be read.
    func groupActionCounts(for group: VMGroupReference) -> [VMGroupAction: Int]? {
        do {
            return try commands.concernedCounts(in: group)
        } catch {
            #log(
                Self.logger, .notice,
                "No group action counts for '\(group.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Takes `action` on every VM in `group`, then puts one account of every VM
    /// it left undone on screen.
    ///
    /// Through ``VMCommanding`` rather than the in-app ``start(_:bootIntoRecovery:)``:
    /// a group action selects and focuses nothing, and raises no question
    /// per VM — the VMs whose own verb would ask are in that one account.
    func performGroupAction(_ action: VMGroupAction, on group: VMGroupReference) async {
        let report: VMGroupActionReport
        do {
            report = try await commands.groupAction(action, on: group)
        } catch let failure as CommandError {
            surfaceUnawaitedFailure(failure)
            return
        } catch {
            surfaceError(error.localizedDescription)
            return
        }
        guard !report.undone.isEmpty else { return }
        surfaceError(report.undoneMessage, title: report.undoneTitle)
    }
}
