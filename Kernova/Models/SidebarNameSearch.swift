import Foundation

/// What the toolbar's search field narrows every sidebar section to: the VMs
/// whose name contains its text.
///
/// Apart from ``SidebarViewOptions`` and its ``VMLibraryFilter``: a smart group
/// saved from the filter, Clear Filters, and `kernova list` never see it.
struct SidebarNameSearch: Equatable, Sendable {
    /// What the field holds, as typed.
    var text = ""

    /// The text a name is matched against: the typed text without its
    /// surrounding whitespace.
    private var term: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the search narrows anything.
    var isActive: Bool { !term.isEmpty }

    /// Whether a VM named `name` matches: always while the search is
    /// inactive, otherwise when the name contains the term, ignoring case and
    /// diacritics.
    func admits(_ name: String) -> Bool {
        let term = term
        return term.isEmpty || name.localizedStandardContains(term)
    }

    /// Of `elements`, in their order, the one a search for this term most
    /// likely meant — by its `name`: one equal to the term, else one the term
    /// begins, else the first it matches; `nil` while the search is inactive or
    /// matches none of them.
    func bestMatch<Element>(in elements: [Element], name: (Element) -> String) -> Element? {
        guard isActive else { return nil }
        let term = term
        let matches = elements.filter { admits(name($0)) }
        let folding: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let equal = matches.first { name($0).compare(term, options: folding) == .orderedSame }
        let begun = matches.first { name($0).range(of: term, options: folding.union(.anchored)) != nil }
        return equal ?? begun ?? matches.first
    }
}
