import AppKit
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// Each section header's count and menu, what the View menu reads of the
/// sidebar, and the commands their picks — and a VM row's folder items — run.
extension SidebarViewController {
    /// The menu `section`'s header button and a right-click on the header
    /// open: the library's filter, group and sort menu, a smart group's own,
    /// or a folder's; `nil` for a section with none.
    func viewMenu(for section: SidebarSectionID) -> NSMenu? {
        viewMenu(for: section, values: SidebarViewMenu.values(of: viewModel))
    }

    /// ``viewMenu(for:)``, counting `values`.
    private func viewMenu(for section: SidebarSectionID, values: [SidebarViewMenu.Value]) -> NSMenu? {
        let organization = viewModel.library.organization
        if section == .library {
            return viewMenu.menu(options: viewModel.sidebarOptions, values: values)
        }
        if let id = section.smartGroupID, let group = organization.smartGroup(withID: id) {
            return viewMenu.menu(
                smartGroup: group, values: values,
                actionCounts: viewModel.groupActionCounts(
                    for: VMGroupReference(.smartGroup, named: id.uuidString)))
        }
        if let id = section.folderID, let folder = organization.folder(withID: id) {
            return viewMenu.menu(
                folder: folder,
                actionCounts: viewModel.groupActionCounts(for: VMGroupReference(.folder, named: id.uuidString)))
        }
        return nil
    }

    /// Whether each section is expanded, in the sidebar's order.
    var sectionExpansion: [Bool] {
        tree.sections.map { outlineView.isItemExpanded($0) }
    }

    /// The kind and header menu of the selected row's section, while that
    /// section is a smart group or a folder, counting `values` — the
    /// library's ``SidebarViewMenu/values(of:)``.
    func selectedGroupMenu(values: [SidebarViewMenu.Value]) -> (kind: VMGroupKind, menu: NSMenu)? {
        guard let section = viewModel.selection?.section, let group = section.group,
            let menu = viewMenu(for: section, values: values)
        else { return nil }
        return (group.kind, menu)
    }

    private func popUpViewMenu(for section: SidebarSectionID, from button: NSButton) {
        viewMenu(for: section)?.popUp(
            positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    /// What `section`'s header shows beside its title; `nil` for a section
    /// with no menu.
    func filtering(for section: SidebarSection) -> SidebarGroupHeaderCellView.Filtering? {
        // The counts the projection the tree lists computed, so they change
        // exactly when the rows do.
        let count = tree.layout.sections.first { $0.id == section.id }?.count
        let organization = viewModel.library.organization
        if let id = section.id.smartGroupID {
            guard let group = organization.smartGroup(withID: id) else { return nil }
            return SidebarGroupHeaderCellView.Filtering(
                countText: count?.text, isActive: false,
                activeDescription: viewMenu.activeFilterDescription(
                    filter: group.filter, values: SidebarViewMenu.values(of: viewModel)),
                buttonLabel: SidebarViewMenu.smartGroupAccessibilityLabel)
        }
        if let id = section.id.folderID {
            guard organization.folder(withID: id) != nil else { return nil }
            return SidebarGroupHeaderCellView.Filtering(
                countText: count?.text, isActive: false, activeDescription: nil,
                buttonLabel: SidebarViewMenu.folderAccessibilityLabel)
        }
        guard section.id == .library else { return nil }
        // The count shows while the search narrows the section too; the
        // button reads active, and describes, only the filter.
        let filter = viewModel.sidebarOptions.filter
        guard filter.isActive else {
            return SidebarGroupHeaderCellView.Filtering(countText: count?.text, isActive: false, activeDescription: nil)
        }
        return SidebarGroupHeaderCellView.Filtering(
            countText: count?.text, isActive: true,
            activeDescription: viewMenu.activeFilterDescription(
                filter: filter, values: SidebarViewMenu.values(of: viewModel)))
    }

    /// Shows `section`'s title — renamed in place for a smart group or a
    /// folder — count and menu button in `cell`.
    func configureHeader(_ cell: SidebarGroupHeaderCellView, for section: SidebarSection) {
        let filtering = filtering(for: section)
        let id = section.id
        cell.configure(
            title: section.title, notice: section.notice,
            renaming: id.group.map { group in
                SidebarGroupHeaderCellView.Renaming(
                    commit: { [weak self, weak section] typed in
                        guard let self else { return }
                        commitRename(of: group.kind, group.id, to: typed)
                        renameEnded(in: section)
                    },
                    cancel: { [weak self, weak section] in
                        guard let self else { return }
                        viewModel.cancelGroupRename(group.kind, group.id)
                        renameEnded(in: section)
                    })
            },
            filtering: filtering,
            onFilterButton: filtering == nil
                ? nil : { [weak self] button in self?.popUpViewMenu(for: id, from: button) })
    }

    /// Renames the `kind` `id` identifies to `typed`, the text its header's
    /// edit was committed with. A name the library refuses opens the edit
    /// again, holding that name, once the refusal is dismissed.
    private func commitRename(of kind: VMGroupKind, _ id: UUID, to typed: String) {
        attempt(
            kind == .smartGroup ? "Couldn\u{2019}t Rename the Smart Group" : "Couldn\u{2019}t Rename the Folder",
            retry: { [weak self] in self?.renameGroup(kind, id, holding: typed) }
        ) { try viewModel.commitGroupRename(kind, id, to: typed) }
    }

    /// Re-renders each section header the outline view has a view for.
    func refreshSectionHeaders() {
        for section in tree.sections {
            let row = outlineView.row(forItem: section)
            guard row >= 0,
                let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? SidebarGroupHeaderCellView
            else { continue }
            configureHeader(cell, for: section)
        }
    }

    // MARK: Commands

    /// Runs what a menu's pick asks for.
    func perform(_ command: SidebarViewMenu.Command) {
        let library = viewModel.library
        switch command {
        case .editOptions(let edit):
            viewModel.library.editSidebarOptions(edit)
        case .saveAsSmartGroup:
            presentSaveAsSmartGroup(library.sidebarOptions.filter)
        case .setSmartGroupFilter(let id, let filter):
            attempt("Couldn\u{2019}t Change the Smart Group") { try library.setFilter(filter, ofSmartGroup: id) }
        case .renameSmartGroup(let id):
            renameGroup(.smartGroup, id)
        case .deleteSmartGroup(let id):
            attempt("Couldn\u{2019}t Delete the Smart Group") { try library.deleteSmartGroup(id) }
        case .newFolder(let entry):
            createFolder(adding: entry)
        case .renameFolder(let id):
            renameGroup(.folder, id)
        case .deleteFolder(let id):
            presentDeleteFolder(id)
        case .setMembership(let entry, let folder, true):
            attempt("Couldn\u{2019}t Add to the Folder") { try library.add([entry], toFolder: folder) }
        case .setMembership(let entry, let folder, false):
            attempt("Couldn\u{2019}t Remove from the Folder") { try library.remove(entry, fromFolder: folder) }
        case .groupAction(let action, let group):
            let viewModel = viewModel
            Task { await viewModel.performGroupAction(action, on: group) }
        case .setTag(let entry, let tag, let isAssigned):
            guard let instance = library.instances.first(where: { $0.id == entry }) else { return }
            attempt("Couldn\u{2019}t Change the Tags") { try library.setTag(tag, assigned: isAssigned, on: instance) }
        case .editTags:
            viewModel.showSettings(at: .pane(.tags))
        case .setSectionsExpanded(let expanded):
            for section in tree.sections {
                if expanded { outlineView.expandItem(section) } else { outlineView.collapseItem(section) }
            }
        }
    }

    /// Asks for a name to save `filter` — the library's filter as the menu
    /// found it — under as a smart group, starting from `name`, a suggestion
    /// from the filter when `nil`. The group saves the filter the sheet shows,
    /// whatever the library's has become by the time it is confirmed. A name
    /// the library refuses brings the sheet back with that name in it.
    private func presentSaveAsSmartGroup(_ filter: VMLibraryFilter, name: String? = nil) {
        guard let window = view.window else { return }
        let values = SidebarViewMenu.values(of: viewModel)
        presentSheetAlert(
            SidebarNameSheet.newSmartGroup(
                suggestedName: name
                    ?? viewModel.library.organization.unusedName(
                        from: viewMenu.suggestedName(for: filter, values: values), for: .smartGroup),
                conditions: viewMenu.conditions(of: filter, values: values)
            ) { [weak self] typed in
                guard let self else { return }
                attempt(
                    "Couldn\u{2019}t Create the Smart Group",
                    retry: { [weak self] in self?.presentSaveAsSmartGroup(filter, name: typed) }
                ) {
                    let group = try viewModel.library.saveSidebarFilter(filter, asSmartGroupNamed: typed)
                    scrollSectionIntoView(.smartGroup(group.id))
                }
            },
            in: window)
    }

    /// Lists a new folder under an unused "Untitled Folder" name, holding the
    /// entry `entry`, if any, and opens its header for a rename, as the
    /// Finder names a new folder.
    private func createFolder(adding entry: UUID?) {
        let library = viewModel.library
        attempt("Couldn\u{2019}t Create the Folder") {
            let folder = try library.createFolder(
                named: library.organization.unusedName(from: "Untitled Folder", for: .folder),
                members: entry.map { [$0] } ?? [])
            renameGroup(.folder, folder.id)
        }
    }

    /// Asks before deleting the folder `id` identifies: its membership was
    /// picked by hand and nothing rebuilds it, as a smart group's filter does.
    private func presentDeleteFolder(_ id: UUID) {
        let library = viewModel.library
        guard let window = view.window, let folder = library.organization.folder(withID: id) else { return }
        let held = folder.members.count { member in library.entries.contains { $0.id == member } }
        presentSheetAlert(
            Self.deleteFolderConfirmation(name: folder.name, memberCount: held) { [weak self] in
                self?.attempt("Couldn\u{2019}t Delete the Folder") { try library.deleteFolder(id) }
            },
            in: window)
    }

    /// The confirmation deleting the folder `name`, holding `memberCount` of
    /// the library's VMs, asks for; Delete runs `delete`.
    static func deleteFolderConfirmation(
        name: String, memberCount: Int, delete: @escaping () -> Void
    ) -> AlertConfiguration {
        let quoted = "\u{201C}\(name)\u{201D}"
        let message =
            switch memberCount {
            case 0: "\(quoted) holds no VMs."
            case 1: "\(quoted) holds 1 VM. Deleting the folder keeps it in the library."
            default: "\(quoted) holds \(memberCount) VMs. Deleting the folder keeps them in the library."
            }
        return AlertConfiguration(
            title: "Delete the Folder \(quoted)?", message: message,
            buttons: [
                AlertButton("Delete", role: .destructive, action: delete),
                AlertButton("Cancel", role: .cancel),
            ])
    }

    /// Runs `change`, showing what it was refused with under `title`, then
    /// `retry` once that alert is dismissed.
    func attempt(_ title: String, retry: (() -> Void)? = nil, _ change: () throws -> Void) {
        do {
            try change()
        } catch {
            let message = error.localizedDescription
            Self.logger.log(.notice, "\(title, privacy: .public): \(message, privacy: .public)")
            guard let window = view.window else { return }
            presentSheetAlert(.acknowledgement(title: title, message: message), in: window, completion: retry)
        }
    }
}
