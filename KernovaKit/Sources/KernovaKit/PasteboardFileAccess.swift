import AppKit
import Foundation
import KernovaFileTree
import KernovaLogging

/// The grants of access to files and folders this process took reading one pasteboard generation's
/// `public.file-url`s, held while anything holds this and let go once nothing does.
///
/// Only the first read of an item's `public.file-url` in a generation takes a grant: a later one takes none, even once
/// that grant is given back (docs/research/2026-11-18-pasteboard-file-grants.md). So every read of a generation
/// shares this one access while it lives, and whatever reaches a file by its path holds the access as long as it
/// does. An item's grant is held until a bookmark of its file is made, which reaches the file from then on wherever
/// it moves, for every later read of the generation too: a copy's read bookmarks each file it can, once whichever
/// reads ask, and a drop's none. A grant is given back by path, so one whose path's folder is gone stays with the
/// process when let go.
@MainActor
public final class PasteboardFileAccess {
    /// What this process read of one pasteboard generation.
    private final class Generation {
        weak var pasteboard: (any ClipboardReadPasteboard)?
        let changeCount: Int
        /// The items whose `public.file-url` this process has read in the generation, granted or not.
        var read: Set<Int> = []
        /// Where the generation's reads are in bookmarking each item's file or folder, by item.
        var bookmarks: [Int: Bookmarking] = [:]
        /// The access holding the generation's grants, while anything holds it.
        weak var access: PasteboardFileAccess?

        init(pasteboard: any ClipboardReadPasteboard, changeCount: Int) {
            self.pasteboard = pasteboard
            self.changeCount = changeCount
        }
    }

    /// Where the generation's reads are in bookmarking one item's file or folder.
    private enum Bookmarking {
        /// A pass is making the bookmark.
        case making(Task<Void, Never>)
        /// Made while the item's grant lasted: how a later read of the generation reaches the file or folder once
        /// the grant is given back.
        case made(Data)
        /// It couldn't be made.
        case refused
    }

    /// Why a bookmark couldn't be made, as the error said.
    private struct Refusal: Error {
        let domain: String
        let code: Int
    }

    /// Each pasteboard's generation this process read last, by the pasteboard's identity.
    private static var generations: [ObjectIdentifier: Generation] = [:]

    private let generation: Generation
    private let grants: SandboxFileGrants
    /// The grant the generation's first read of each item took, by item, until a bookmark of its file is kept.
    private var granted: [Int: SandboxFileGrants.Grant] = [:]

    private init(generation: Generation, grants: SandboxFileGrants) {
        self.generation = generation
        self.grants = grants
    }

    /// The access a read of `pasteboard` as it stands at `changeCount` takes its grants into: the one every read of
    /// that generation shares while anything holds it.
    static func reading(_ pasteboard: any ClipboardReadPasteboard, at changeCount: Int) -> PasteboardFileAccess {
        let key = ObjectIdentifier(pasteboard)
        let generation: Generation
        if let last = generations[key], last.pasteboard === pasteboard, last.changeCount == changeCount {
            if let access = last.access { return access }
            generation = last
        } else {
            generations = generations.filter { $0.value.pasteboard != nil }
            generation = Generation(pasteboard: pasteboard, changeCount: changeCount)
            generations[key] = generation
        }
        let access = PasteboardFileAccess(generation: generation, grants: pasteboard.fileGrants)
        generation.access = access
        return access
    }

    /// The `public.file-url` of `item`, the generation's item `index`, read now. The generation's first read of
    /// it took a grant of what it names, which this access holds until it keeps a bookmark of it.
    func fileURL(ofItem index: Int, _ item: any ClipboardPasteboardItemReading) -> String? {
        let string = item.string(forType: .fileURL)
        guard let string, let url = URL(string: string), url.isFileURL, generation.read.insert(index).inserted
        else { return string }
        granted[index] = grants.pasteboardGranted(url)
        return string
    }

    /// The file URL each of `pasteboard`'s items names as it stands now, read into the access every read of it
    /// shares, and that access, which whatever reads the files holds until it has.
    public static func readFileURLs(
        from pasteboard: any ClipboardReadPasteboard
    ) -> (urls: [URL], access: PasteboardFileAccess) {
        let access = reading(pasteboard, at: pasteboard.changeCount)
        let urls = pasteboard.items.enumerated().compactMap { index, item in
            access.fileURL(ofItem: index, item).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        }
        return (urls, access)
    }

    /// The bookmark a read of the generation made of item `index`'s file or folder, if one did.
    func bookmark(ofItem index: Int) -> Data? {
        guard case .made(let bookmark) = generation.bookmarks[index] else { return nil }
        return bookmark
    }

    /// Bookmarks each of `files`, the generation's items' files or folders by item, that no read of the generation
    /// has bookmarked or is bookmarking: off the main actor, while this access holds the grants the reads took, in
    /// one pass whichever reads ask. The task ends once every one of `files` is bookmarked or refused one; a bookmark
    /// made gives its item's grant back, and an item refused one keeps it, reached by its path.
    func bookmarking(_ files: [(item: Int, url: URL)]) -> Task<Void, Never> {
        var passes: [Task<Void, Never>] = files.compactMap {
            guard case .making(let pass) = generation.bookmarks[$0.item] else { return nil }
            return pass
        }
        let unmarked = files.filter { generation.bookmarks[$0.item] == nil }
        if !unmarked.isEmpty {
            let grants = grants
            let pass = Task { [self] in
                let made = await Task.detached { Self.bookmarks(of: unmarked, through: grants) }.value
                for (file, made) in zip(unmarked, made) { settle(item: file.item, made) }
            }
            for file in unmarked { generation.bookmarks[file.item] = .making(pass) }
            passes.append(pass)
        }
        return Task {
            for pass in passes { await pass.value }
        }
    }

    /// Settles item `index`'s bookmarking with `made`: a bookmark is kept for every later read of the generation and
    /// gives the item's grant back; a refusal leaves the grant held.
    private func settle(item index: Int, _ made: Result<Data, Refusal>) {
        switch made {
        case .success(let bookmark):
            generation.bookmarks[index] = .made(bookmark)
            granted.removeValue(forKey: index)?.release()
        case .failure(let refusal):
            generation.bookmarks[index] = .refused
            guard granted[index] != nil else { return }
            grants.logger.log(
                .notice,
                "Copied item \(index, privacy: .public)'s file couldn't be bookmarked (\(refusal.domain, privacy: .public) \(refusal.code, privacy: .public)), so its offer reaches it by its path, holding its access"
            )
        }
    }

    /// A bookmark of each of `files`, or why it couldn't be made, made through `grants` without downloading a
    /// dataless file.
    nonisolated private static func bookmarks(
        of files: [(item: Int, url: URL)], through grants: SandboxFileGrants
    ) -> [Result<Data, Refusal>] {
        DatalessMaterialization.off.during {
            files.map { file in
                // A link is bookmarked as what it resolves to, which is what is read.
                let isLink = (try? file.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                do {
                    return .success(try grants.bookmark(of: isLink ? file.url.resolvingSymlinksInPath() : file.url))
                } catch {
                    let error = error as NSError
                    return .failure(Refusal(domain: error.domain, code: error.code))
                }
            }
        }
    }

    /// Whether this holds any grant.
    public var holdsGrants: Bool { !granted.isEmpty }

    /// Whether the pasteboard read still stands at the generation it read.
    public var standsOnItsPasteboard: Bool {
        generation.pasteboard.map { $0.changeCount == generation.changeCount } ?? false
    }
}
