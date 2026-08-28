import AVFoundation
import AppKit

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
    /// Decides whether that picker offers Bridged at all.
    let entitlements: EntitlementService
    let vmnetNetworks: any VmnetNetworkProviding
    let micPermissionStatus: @MainActor () -> AVAuthorizationStatus
    let systemSettings: SystemSettingsLink

    /// The shell, which owns the write paths a panel shares with the overview.
    weak var host: (any VMSettingsPanelHost)?

    /// `true` while the pane is off screen, so an async read that lands late
    /// paints nothing. The shell drives it from its own appearance callbacks;
    /// AppKit's forwarding to hidden children is not dependable.
    private(set) var isDismissed = false

    init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        isReadOnly: Bool,
        bridgedInterfaces: any BridgedInterfaceProviding,
        entitlements: EntitlementService,
        vmnetNetworks: any VmnetNetworkProviding,
        micPermissionStatus: @escaping @MainActor () -> AVAuthorizationStatus,
        systemSettings: SystemSettingsLink
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        self.bridgedInterfaces = bridgedInterfaces
        self.entitlements = entitlements
        self.vmnetNetworks = vmnetNetworks
        self.micPermissionStatus = micPermissionStatus
        self.systemSettings = systemSettings
    }

    /// Rebinds every panel at once; the shell calls this inside `reconfigure`.
    func rebind(instance: VMInstance, viewModel: VMLibraryViewModel, isReadOnly: Bool) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
    }

    func setDismissed(_ isDismissed: Bool) {
        self.isDismissed = isDismissed
    }
}

/// What a panel asks of the settings shell.
///
/// A panel resolves its own sheets and popovers from `view.window` — panels stay
/// in the view hierarchy while hidden — so the host answers only for state the
/// shell owns.
@MainActor
protocol VMSettingsPanelHost: AnyObject {
    /// Routes a mirrored toggle into the shell's one write path for it, the same
    /// one the overview card's switch takes.
    func settingsPanel(
        _ panel: any VMSettingsPanel, setToggle toggle: VMOverviewToggle, to isOn: Bool)
    /// Re-renders every surface from the model — for a write the panel could not
    /// complete, or one whose effect reaches beyond the panel.
    func settingsPanelRequestsFullRefresh()
}

/// One category's form: builds its sections, refreshes them from the model, and
/// contributes what its own state adds to the overview.
///
/// Panels never override the appearance callbacks — AppKit's forwarding to a
/// hidden child view controller is not dependable — so the shell drives
/// ``prepareForDisappearance()`` and ``hostDidBecomeActive()`` itself.
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
    /// Adds what this panel resolved to the values the overview cards state.
    func contribute(to resolved: inout VMOverviewResolved)
    /// The pane is going away: cancel work and drop in-flight edit state.
    func prepareForDisappearance()
    /// The app came forward; re-read anything the system may have changed.
    func hostDidBecomeActive()
}

extension VMSettingsPanel {
    func willRebind() {}
    func contribute(to resolved: inout VMOverviewResolved) {}
    func prepareForDisappearance() {}
    func hostDidBecomeActive() {}

    var chrome: VMSettingsPanelChrome { VMSettingsPanelChrome() }

    var instance: VMInstance { context.instance }
    var viewModel: VMLibraryViewModel { context.viewModel }
    var isReadOnly: Bool { context.isReadOnly }

    /// - Returns: Whether the mutation was applied, so a caller whose control
    ///   already moved can put it back when the view model refused.
    @discardableResult
    func writeConfig(_ mutate: (inout VMConfiguration) -> Void) -> Bool {
        viewModel.updateConfiguration(of: instance, mutate: mutate)
    }

    /// Hands a toggle this panel shares with an overview card to the shell, so
    /// both surfaces write through one path.
    func setToggle(_ toggle: VMOverviewToggle, to isOn: Bool) {
        context.host?.settingsPanel(self, setToggle: toggle, to: isOn)
    }

    func requestFullRefresh() {
        context.host?.settingsPanelRequestsFullRefresh()
    }
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
        _ title: String, lockable: Bool = false, paragraphs: [InfoPopoverParagraph] = [],
        lockHintSink: ((NSView) -> Void)? = nil
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
            views.append(makeLockHint(sink: lockHintSink))
        }

        let header = NSStackView(views: views)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Spacing.small
        return header
    }

    /// A lock hint registered here, for a section header or the panel header a
    /// single-section category hands its chrome to.
    mutating func makeLockHint(sink: ((NSView) -> Void)? = nil) -> NSView {
        let hint = makeGroupedFormLockHint()
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
