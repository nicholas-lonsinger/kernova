import Foundation
import KernovaLogging

/// The library's tags: their definitions, changed through ``organization``,
/// and each VM's assignments, written to its ``VMHostState/tags``.
///
/// What a VM carries is its assignments the library defines
/// (``Swift/Sequence/assigned(_:)``), so an assignment naming a deleted tag —
/// one a VM held by another copy kept, or an imported VM brought — shows
/// nowhere, and a filter condition on one admits no VM.
extension VMLibrary {
    /// Why a VM's tags did not change.
    enum TagChangeRefusal: LocalizedError, Equatable {
        /// The VM's state takes no tag change now.
        case refused(VMAdmission.Refusal)

        var errorDescription: String? {
            switch self {
            case .refused(.heldByAnotherCopy):
                VMLibrary.SettingsRefusal.heldByAnotherCopy.errorDescription
            case .refused:
                "The virtual machine\u{2019}s current state doesn\u{2019}t allow changing its tags."
            }
        }
    }

    /// Every tag, in the order every list of them shows them; `nil` while the
    /// file defining them can't be read.
    var tags: [VMTag]? { organization.tags }

    /// The tags `instance` carries, in the library's order of its tags: none
    /// while the file defining them can't be read, since an assignment shows
    /// only the tags the library defines.
    func tags(of instance: VMInstance) -> [VMTag] {
        (organization.tags ?? []).assigned(instance.hostState.tags)
    }

    /// Defines a new tag named `name` in `color`.
    @discardableResult
    func createTag(named name: String, color: VMTagColor) throws -> VMTag {
        try organization.createTag(named: name, color: color)
    }

    /// Renames the tag `id` identifies.
    func renameTag(_ id: UUID, to name: String) throws {
        try organization.renameTag(id, to: name)
    }

    /// Shows the tag `id` identifies in `color`.
    func setColor(_ color: VMTagColor, ofTag id: UUID) throws {
        try organization.setColor(color, ofTag: id)
    }

    /// Deletes the tag `id` identifies — its definition, then each VM's
    /// assignment.
    ///
    /// A filter naming it — a smart group's, the library section's — keeps
    /// the condition, which no VM passes from then on, until the user clears
    /// it. A VM whose state takes no edit now keeps the assignment, which is
    /// inert.
    func deleteTag(_ id: UUID) throws {
        try organization.removeTag(id)
        for instance in instances where instance.hostState.tags.contains(id) {
            do {
                try changeTags(of: instance) { $0.remove(id) }
            } catch {
                #log(
                    Self.logger, .notice,
                    "Kept the deleted tag's assignment on '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        reconcileSelection()
    }

    /// Puts the tag `id` identifies on `instance`, or takes it off.
    func setTag(_ id: UUID, assigned: Bool, on instance: VMInstance) throws {
        try changeTags(of: instance) { tags in
            if assigned {
                tags.insert(id)
            } else {
                tags.remove(id)
            }
        }
    }

    /// Commits `change` to what `instance`'s `host-state.json` holds of its
    /// tags, as the ``VMCapability/editTags`` edit.
    private func changeTags(of instance: VMInstance, _ change: (inout Set<UUID>) -> Void) throws {
        guard let classes = VMCapability.editTags.editClasses else {
            preconditionFailure("A tag change is an edit")
        }
        do {
            try instance.activity.edit(classes) { permit in
                try updateHostState(permit) { change(&$0.tags) }.get()
            }
        } catch let refused as VMAdmissionRefusal {
            throw TagChangeRefusal.refused(refused.refusal)
        }
    }
}
