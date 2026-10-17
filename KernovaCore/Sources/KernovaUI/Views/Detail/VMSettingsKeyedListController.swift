import AppKit

/// The rebuild/in-place-update engine behind a settings list of keyed rows —
/// storage disks, removable media, shared directories, snapshots.
///
/// A structural change (rows added, removed, or reordered) rebuilds the stack;
/// anything else updates the affected rows in place. Only the structural path
/// tears down an in-progress editing field, so only it waits on ``activeEdit``.
///
/// The owner supplies the per-list differences: what a row view is, how a model
/// is written into one, and — for a list whose subtitle holds a figure read off
/// the main actor — how that read is started.
@MainActor
final class VMSettingsKeyedListController<Model: Identifiable & Equatable, Row: NSView>
where Model.ID == UUID {
    private let listStack: NSStackView
    /// Rendered in place of the rows when the list is empty; `nil` renders
    /// nothing.
    private let emptyMessage: String?
    /// Inserted between adjacent rows, for a list that separates them.
    private let separator: (() -> NSView)?

    /// Live row views keyed by model id, so a menu item can reach the row it
    /// belongs to and a late read can land on the right subtitle.
    private(set) var rowsByID: [UUID: Row] = [:]

    /// What the rows were last rendered from, so a pass that changed nothing
    /// about a row skips it.
    private(set) var rendered: [Model]?

    /// The row being renamed or noted inline, or `nil`. While set, a structural
    /// rebuild is deferred so a refresh landing mid-edit can't destroy the
    /// editing field.
    var activeEdit: UUID?

    init(
        listStack: NSStackView,
        emptyMessage: String? = nil,
        separator: (() -> NSView)? = nil
    ) {
        self.listStack = listStack
        self.emptyMessage = emptyMessage
        self.separator = separator
    }

    /// The live row view showing `id`, or `nil` once it is gone.
    func row(_ id: UUID) -> Row? {
        rowsByID[id]
    }

    /// Renders `models`, rebuilding the stack only when their identities or
    /// order changed.
    ///
    /// `readsUnchangedRows` re-runs `readLiveSubtitle` for rows nothing changed
    /// about — what a list whose subtitle holds a figure that moves on its own
    /// (a running guest's disk sizes) needs, and what a list whose subtitle is
    /// stable must not pay.
    ///
    /// The hooks are taken per call rather than stored: the engine is a
    /// property of the view that owns these closures, and storing them would
    /// close the retain cycle.
    func update(
        _ models: [Model],
        readsUnchangedRows: Bool = false,
        makeRow: (Model) -> Row,
        applyRow: (Model, Row) -> Void,
        readLiveSubtitle: (Model, Row) -> Void = { _, _ in }
    ) {
        let previous = rendered
        let structural = previous?.map(\.id) != models.map(\.id)

        if structural {
            // A rebuild would destroy an in-progress editing field, so defer it
            // until the edit ends (the cancel/commit handler re-runs the refresh).
            if activeEdit != nil { return }
            rendered = models
            clearGroupedFormStack(listStack)
            rowsByID.removeAll(keepingCapacity: true)
            guard !models.isEmpty else {
                if let emptyMessage {
                    addGroupedFormFullWidth(makeGroupedFormSecondaryLabel(emptyMessage), to: listStack)
                }
                return
            }
            for (index, model) in models.enumerated() {
                if index > 0, let separator {
                    addGroupedFormFullWidth(separator(), to: listStack)
                }
                let row = makeRow(model)
                rowsByID[model.id] = row
                addGroupedFormFullWidth(row, to: listStack)
                applyRow(model, row)
                // Freshly built rows start with an empty subtitle — read once.
                readLiveSubtitle(model, row)
            }
            return
        }

        rendered = models
        let previousByID = Dictionary(
            (previous ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for model in models {
            guard let row = rowsByID[model.id] else { continue }
            let changed = previousByID[model.id] != model
            guard changed || readsUnchangedRows else { continue }
            if changed { applyRow(model, row) }
            readLiveSubtitle(model, row)
        }
    }
}
