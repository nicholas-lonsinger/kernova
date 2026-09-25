import AVFoundation
import AppKit
import KernovaKit

/// The bindings every settings panel reads: the VM under edit, the view model
/// to write through, the read-only state, and the injected services a panel
/// needs to build itself.
///
/// One instance per settings pane, mutated by the shell on `reconfigure` and
/// read — never written — by the panels, so a rebind is one write rather than
/// six.
@MainActor
final class VMSettingsPanelContext {
    private(set) var instance: VMInstance
    private(set) var viewModel: VMLibraryViewModel
    private(set) var isReadOnly: Bool

    /// Host interfaces offered by the Network panel's Mode picker.
    let bridgedInterfaces: any BridgedInterfaceProviding
    let micPermissionStatus: @MainActor () -> AVAuthorizationStatus
    let systemSettings: SystemSettingsLink

    /// The one resolution of everything the configuration cannot answer, which
    /// the overview's cards and the panels stating the same figure both read.
    let overview: VMOverviewResolver

    /// Existence of every attachment file this VM's rows stand for, shared by
    /// the panels that render those rows so one watch serves them all.
    let fileMonitor: AttachmentFileMonitor

    /// The shell, which owns the write paths a panel shares with the overview.
    weak var host: (any VMSettingsPanelHost)?

    /// `true` while the pane is off screen, so an async read that lands late
    /// paints nothing. The shell drives it from its own appearance callbacks;
    /// AppKit's forwarding to a child whose view is out of the tree is not
    /// dependable.
    private(set) var isDismissed = false

    init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        isReadOnly: Bool,
        bridgedInterfaces: any BridgedInterfaceProviding,
        micPermissionStatus: @escaping @MainActor () -> AVAuthorizationStatus,
        systemSettings: SystemSettingsLink,
        activationCenter: NotificationCenter
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        self.bridgedInterfaces = bridgedInterfaces
        self.micPermissionStatus = micPermissionStatus
        self.systemSettings = systemSettings
        self.fileMonitor = AttachmentFileMonitor(activationCenter: activationCenter)
        self.overview = VMOverviewResolver(
            instance: instance, viewModel: viewModel,
            bridgedInterfaces: bridgedInterfaces, micPermissionStatus: micPermissionStatus)
    }

    /// Rebinds every panel at once; the shell calls this inside `reconfigure`.
    func rebind(instance: VMInstance, viewModel: VMLibraryViewModel, isReadOnly: Bool) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        overview.bind(instance: instance, viewModel: viewModel)
    }

    func setDismissed(_ isDismissed: Bool) {
        self.isDismissed = isDismissed
    }

    /// Points the file monitor at the current instance's monitored attachment
    /// paths.
    ///
    /// Idempotent, and every caller computes the same union, so the panels that
    /// render those rows each seed it from their own `rebuild()` and `refresh()`
    /// — which is what keeps the watch off a VM whose settings nobody opened.
    func seedFileMonitor() {
        let refs = instance.configuration.externalFileReferences
            .filter(\.kind.isExistenceMonitored).bookmarksByPath
        Task { [fileMonitor] in await fileMonitor.setPaths(refs) }
    }
}

/// What a panel asks of the settings shell.
///
/// A panel resolves its own sheets and popovers from `view.window`, so the host
/// answers only for state the shell owns.
@MainActor
protocol VMSettingsPanelHost: AnyObject {
    /// Routes a mirrored toggle into the shell's one write path for it, the same
    /// one the overview card's switch takes.
    func settingsPanel(
        _ panel: any VMSettingsPanel, setToggle toggle: VMOverviewToggle, to isOn: Bool)
}

/// One category's form: builds its sections and refreshes them from the model.
///
/// A panel exists only while its category is open, so nothing here runs for a
/// category the user has not drilled into. Panels never override the appearance
/// callbacks — AppKit's forwarding to a child view controller whose view is out
/// of the tree is not dependable — so the shell drives
/// ``prepareForDisappearance()`` itself.
@MainActor
protocol VMSettingsPanel: NSViewController {
    var context: VMSettingsPanelContext { get }
    var category: VMSettingsCategory { get }
    /// Header pieces a single-section category hands to the panel header.
    var chrome: VMSettingsPanelChrome { get }

    /// Builds this panel's per-instance structure; called on load and on every
    /// switch to a different VM.
    func rebuild()
    /// Repaints every control from the model. Idempotent.
    func refresh()

    /// Runs against the *outgoing* instance, before the context rebinds.
    func willRebind()
    /// The pane is on screen again: re-arm anything ``prepareForDisappearance()``
    /// let go of. Runs after the context is un-dismissed and before `refresh()`.
    func hostDidAppear()
    /// The pane is going away: cancel work and drop in-flight edit state.
    func prepareForDisappearance()
}

extension VMSettingsPanel {
    func willRebind() {}
    func hostDidAppear() {}
    func prepareForDisappearance() {}

    var chrome: VMSettingsPanelChrome { VMSettingsPanelChrome() }

    var instance: VMInstance { context.instance }
    var viewModel: VMLibraryViewModel { context.viewModel }
    /// Whether the *route* opened this pane read-only, which is the pane's
    /// chrome: the lock hints, the dimming, the captions.
    ///
    /// Not a control's gate. What a control may do is the capability its verb
    /// refuses on (``VMCapabilityCatalog/isAvailable(_:on:)``) — a second
    /// surface asking the same question has to get the same answer, and only the
    /// capability is the answer the verb behind the control will honour.
    var isReadOnly: Bool { context.isReadOnly }
    /// The figures this panel shares with the overview's cards, resolved once.
    var resolved: VMOverviewResolved { context.overview.resolved }

    /// Writes `assignments` through the configuration verb, the one path a
    /// panel's edit takes.
    ///
    /// An edit that does not land repaints the panel from the model, so no
    /// control is left showing a value that was not saved; the verb has already
    /// told the user why.
    ///
    /// - Returns: Whether the edit was applied.
    @discardableResult
    func write(_ assignments: ConfigurationEntry...) -> Bool {
        guard case .applied = viewModel.setConfiguration(assignments, on: instance) else {
            refresh()
            return false
        }
        return true
    }

    /// Hands a toggle this panel shares with an overview card to the shell, so
    /// both surfaces write through one path.
    func setToggle(_ toggle: VMOverviewToggle, to isOn: Bool) {
        context.host?.settingsPanel(self, setToggle: toggle, to: isOn)
    }

    /// Re-resolves ``resolved`` after a write one of its values reads, so the
    /// panel's own re-render doesn't state what the model held a moment ago.
    func refreshResolved() {
        context.overview.refresh()
    }
}

extension NSTextField {
    /// Paints `value` from the model unless the user is typing in the field.
    ///
    /// Every panel refresh paints its fields through this: any refresh — an
    /// observation pass, a status change a CLI start makes — would otherwise
    /// replace the keystrokes typed so far, and the edit reaches the model only
    /// through its end-edit, which ends in ``showEndedEdit(_:)``.
    func showUnlessEditing(_ value: String) {
        guard currentEditor() == nil else { return }
        stringValue = value
    }

    /// Shows `value` in a field whose edit just ended, written or refused.
    ///
    /// At end-edit time the editor can still be attached, holding the text just
    /// consumed; a value set beneath it does not read back
    /// (`refusedEndEditRevertsAFieldStillBeingEdited`), so the editor is
    /// discarded first.
    func showEndedEdit(_ value: String) {
        abortEditing()
        stringValue = value
    }
}

/// Puts `string` on the host pasteboard, for a panel's copy affordance.
@MainActor
func copyToPasteboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

/// What a panel header shows in place of a single section's own header.
struct VMSettingsPanelChrome {
    var leading: [NSView] = []
    var trailing: [NSView] = []
}

/// A panel's record of what only a stopped VM can change.
///
/// One registry per panel rather than one shared by the shell: a panel's
/// rebuild clears exactly its own rows, and nothing else can strand a hint from
/// a section that no longer exists.
@MainActor
struct VMSettingsLockRegistry {
    /// "Editable when stopped" hints on lockable section headers; shown only
    /// while read-only.
    private(set) var hints: [NSView] = []
    /// Form rows that only a stopped VM can change: their controls go inert and
    /// the whole row dims while read-only (per-row controls in the dynamic lists
    /// set their own enabled state when those lists are rebuilt).
    private(set) var rows: [(row: NSView, controls: [NSControl])] = []

    mutating func removeAll() {
        hints.removeAll()
        rows.removeAll()
    }

    /// Registers `row` as editable only while the VM is stopped, returning it so
    /// it can be handed straight to a card.
    @discardableResult
    mutating func lockable(_ row: NSView, _ controls: NSControl...) -> NSView {
        rows.append((row: row, controls: controls))
        return row
    }

    /// Section header; any lock hint it creates is registered here and toggled
    /// by ``apply(isReadOnly:)``. A section whose lock is conditional passes
    /// `lockHintSink` to keep its own reference — by handoff, not by position.
    mutating func makeHeader(
        _ title: String, lockable: Bool = false, lockHintText: String = groupedFormLockHintText,
        paragraphs: [InfoPopoverParagraph] = [], lockHintSink: ((NSView) -> Void)? = nil
    ) -> NSView {
        var views: [NSView] = [makeGroupedFormSectionHeader(title)]
        if !paragraphs.isEmpty {
            views.append(makeGroupedFormInfoButton(label: title, paragraphs: paragraphs))
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        if lockable {
            views.append(makeLockHint(text: lockHintText, sink: lockHintSink))
        }

        let header = NSStackView(views: views)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Spacing.small
        return header
    }

    /// A lock hint registered here, for a section header or the panel header a
    /// single-section category hands its chrome to.
    mutating func makeLockHint(
        text: String = groupedFormLockHintText, sink: ((NSView) -> Void)? = nil
    ) -> NSView {
        let hint = makeGroupedFormLockHint(text: text)
        hint.isHidden = true
        hints.append(hint)
        sink?(hint)
        return hint
    }

    /// Shows every hint and dims every locked row for a read-only pane.
    func apply(isReadOnly: Bool) {
        hints.forEach { $0.isHidden = !isReadOnly }
        for entry in rows {
            entry.controls.forEach { $0.isEnabled = !isReadOnly }
            entry.row.alphaValue = isReadOnly ? Alpha.disabled : 1
        }
    }
}

/// Value snapshot of one attachment, share or media row's rendered appearance,
/// used to skip rebuilding a list when nothing it displays has changed.
struct VMSettingsRenderedRow: Identifiable, Equatable {
    let id: UUID
    let iconSystemName: String
    let title: String
    let notes: String
    let subtitle: String
    let isMissing: Bool
    let missingPath: String?
    let readOnly: Bool
    let controlsEnabled: Bool
}

/// The item id a row control carries in its `identifier`.
@MainActor
func attachmentUUID(from sender: Any?) -> UUID? {
    guard let raw = (sender as? NSView)?.identifier?.rawValue else { return nil }
    return UUID(uuidString: raw)
}
