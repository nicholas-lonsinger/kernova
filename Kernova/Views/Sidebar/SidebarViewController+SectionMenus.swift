import AppKit
import KernovaKit
import KernovaLogging

/// Each section header's count and menu, what the View menu reads of the
/// sidebar, and the commands their picks — and a VM row's folder items — run.
extension SidebarViewController {
    /// The menu `section`'s header button and a right-click on the header
    /// open: the library's filter, group and sort menu, a smart group's own,
    /// or a folder's; `nil` for a section with none.
    func viewMenu(for section: SidebarSectionID) -> NSMenu? {
        let organization = viewModel.library.organization
        if section == .library {
            return viewMenu.menu(options: viewModel.sidebarOptions, values: SidebarViewMenu.values(of: viewModel))
        }
        if let id = section.smartGroupID, let group = organization.smartGroup(withID: id) {
            return viewMenu.menu(
                smartGroup: group, values: SidebarViewMenu.values(of: viewModel),
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
    /// section is a smart group or a folder.
    func selectedGroupMenu() -> (kind: VMGroupKind, menu: NSMenu)? {
        guard let section = viewModel.selection?.section else { return nil }
        let kind: VMGroupKind? = section.smartGroupID != nil ? .smartGroup : section.folderID != nil ? .folder : nil
        guard let kind, let menu = viewMenu(for: section) else { return nil }
        return (kind, menu)
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

    /// Shows `section`'s title, count and menu button in `cell`.
    func configureHeader(_ cell: SidebarGroupHeaderCellView, for section: SidebarSection) {
        let filtering = filtering(for: section)
        let id = section.id
        cell.configure(
            title: section.title, filtering: filtering,
            onFilterButton: filtering == nil
                ? nil : { [weak self] button in self?.popUpViewMenu(for: id, from: button) })
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
            presentSaveAsSmartGroup()
        case .setSmartGroupFilter(let id, let filter):
            attempt("Couldn\u{2019}t Change the Smart Group") { try library.setFilter(filter, ofSmartGroup: id) }
        case .renameSmartGroup(let id):
            presentRename(.smartGroup, id)
        case .deleteSmartGroup(let id):
            attempt("Couldn\u{2019}t Delete the Smart Group") { try library.deleteSmartGroup(id) }
        case .newFolder(let entry):
            presentNewFolder(adding: entry)
        case .renameFolder(let id):
            presentRename(.folder, id)
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
            NSApp.sendAction(#selector(AppDelegate.showTagsSettings(_:)), to: nil, from: self)
        case .setSectionsExpanded(let expanded):
            for section in tree.sections {
                if expanded { outlineView.expandItem(section) } else { outlineView.collapseItem(section) }
            }
        }
    }

    /// Asks for a name to save the library's filter under as a smart group,
    /// starting from `name` — a suggestion from the filter when `nil`. A name
    /// the library refuses brings the sheet back with that name in it.
    private func presentSaveAsSmartGroup(name: String? = nil) {
        guard let window = view.window else { return }
        let filter = viewModel.sidebarOptions.filter
        let values = SidebarViewMenu.values(of: viewModel)
        presentSheetAlert(
            SidebarNameSheet.newSmartGroup(
                suggestedName: name
                    ?? viewModel.library.organization.unusedName(
                        from: viewMenu.suggestedName(for: filter, values: values), for: .smartGroup),
                conditions: viewMenu.conditions(of: filter, values: values)
            ) { [weak self] typed in
                self?.attempt(
                    "Couldn\u{2019}t Create the Smart Group",
                    retry: { [weak self] in self?.presentSaveAsSmartGroup(name: typed) }
                ) { try self?.viewModel.library.saveSidebarFilterAsSmartGroup(named: typed) }
            },
            in: window)
    }

    /// Asks for the name of a new folder, starting from `name` — an unused
    /// "Untitled Folder" when `nil` — which then holds the entry `entry`, if
    /// any. A name the library refuses brings the sheet back with that name
    /// in it.
    private func presentNewFolder(adding entry: UUID?, name: String? = nil) {
        guard let window = view.window else { return }
        presentSheetAlert(
            SidebarNameSheet.newFolder(
                suggestedName: name
                    ?? viewModel.library.organization.unusedName(from: "Untitled Folder", for: .folder)
            ) { [weak self] typed in
                self?.attempt(
                    "Couldn\u{2019}t Create the Folder",
                    retry: { [weak self] in self?.presentNewFolder(adding: entry, name: typed) }
                ) { try self?.viewModel.library.createFolder(named: typed, members: entry.map { [$0] } ?? []) }
            },
            in: window)
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

    /// Asks for a new name for the `kind` `id` identifies, starting from
    /// `name` — its current one when `nil`. A name the library refuses brings
    /// the sheet back with that name in it.
    private func presentRename(_ kind: VMGroupKind, _ id: UUID, name: String? = nil) {
        let library = viewModel.library
        let current: String? =
            switch kind {
            case .smartGroup: library.organization.smartGroup(withID: id)?.name
            case .folder: library.organization.folder(withID: id)?.name
            }
        guard let window = view.window, let current else { return }
        presentSheetAlert(
            SidebarNameSheet.rename(kind, currentName: name ?? current) { [weak self] typed in
                self?.attempt(
                    kind == .smartGroup
                        ? "Couldn\u{2019}t Rename the Smart Group" : "Couldn\u{2019}t Rename the Folder",
                    retry: { [weak self] in self?.presentRename(kind, id, name: typed) }
                ) {
                    switch kind {
                    case .smartGroup: try library.renameSmartGroup(id, to: typed)
                    case .folder: try library.renameFolder(id, to: typed)
                    }
                }
            },
            in: window)
    }

    /// Runs `change`, showing what it was refused with under `title`, then
    /// `retry` once that alert is dismissed.
    func attempt(_ title: String, retry: (() -> Void)? = nil, _ change: () throws -> Void) {
        do {
            try change()
        } catch {
            let message = error.localizedDescription
            #log(Self.logger, .notice, "\(title, privacy: .public): \(message, privacy: .public)")
            guard let window = view.window else { return }
            presentSheetAlert(.acknowledgement(title: title, message: message), in: window, completion: retry)
        }
    }
}
