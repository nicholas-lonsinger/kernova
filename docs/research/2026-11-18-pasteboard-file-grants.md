# The sandbox grants a pasteboard read takes, and giving them back

**Date:** 2026-11-18 · **Host:** macOS 27.2.1 (26B131), command-line probes

## Question

When a sandboxed process reads a file URL off a pasteboard, which reads take a grant of access to the file, what
does giving one back with `stopAccessingSecurityScopedResource()` take away, and what does it do to a grant of
the same path that a security-scoped bookmark holds?

## Method

An unsandboxed writer created files and folders and wrote their `NSURL`s to a private named pasteboard
(`NSPasteboard(name:)`), one item per URL, every name the same length. A reader, ad-hoc signed with
`com.apple.security.app-sandbox` and `com.apple.security.files.bookmarks.app-scope`, ran a script of steps in one
process, the writer writing a new generation between steps where a step says so:

- read items' `public.file-url` by `string(forType:)`, by `data(forType:)`, or by
  `readObjects(forClasses: [NSURL.self])`, from the items of an earlier fetch or a fresh `pasteboardItems`;
- `open(2)` each path read, which fails `EPERM` without a grant;
- call `stopAccessingSecurityScopedResource()` on `URL(fileURLWithPath:)` of a path;
- make an app-scoped bookmark of a path while it was granted, resolve it, and start or stop its access;
- read every item's `types`, `canReadObject(forClasses: [NSURL.self])` and
  `readObjects(forClasses: [NSFilePromiseReceiver.self])`;
- meter the grants left: read fresh files until the first `open` fails.

Each scenario ran in a fresh process. A fresh process's meter read 1,456 files of 213-character paths before the
first failed, about 496 KB at path length plus 128 bytes each.

## Observed

1. A process's first read of an item's file URL in a pasteboard generation, by any of the three reads, takes a
   grant. A later read of the same item in that generation, from the same objects or a fresh fetch, takes none:
   two reads of 400 items cost the meter 400 grants, and one give-back of each path then left none open.
2. Once its grant is given back, no read of the item in that generation, by any of the three reads, grants it again.
3. Grants are counted per exact path, the budget charged once per path. Two items naming the same path took two
   grants for one path's cost; one give-back per path left every path open, a second closed them and returned the
   whole meter. So did reads of the same files in two generations.
4. A give-back takes one grant of the path, whoever took it. With a bookmark's access started and a read in a new
   generation of the same path, one give-back on the plain URL left the path open and the bookmark's stop closed it,
   in either order of the start and the read, and with the give-backs in either order. With the bookmark's access
   alone — the read of a generation already read, which took nothing — one give-back on the plain URL closed the
   path to the bookmark's holder.
5. With the meter spent, a read of a path whose bookmark access was started returned the URL and took no grant: one
   give-back on the plain URL closed the path.
6. A give-back of a path matches it exactly: a folder's grant survived the give-back of a file inside it, whether or
   not that file held a grant of its own.
7. `types`, `canReadObject(forClasses: [NSURL.self])` and `readObjects(forClasses: [NSFilePromiseReceiver.self])`
   of file items took no grant.
8. A path without a grant still answers `lstat(2)` and `FileManager.fileExists(atPath:)`.

## Consequence

A grant a pasteboard read took is given back exactly once, and only by what recorded taking it, since a give-back
for a read that took nothing takes a grant another holder of the path took. Which reads took one is decided by
the first read of each item in a generation, so every read of a generation shares one record of them. Nothing
answers whether a read took a grant (5), so a pasteboard read's give-back waits until no other holder of the path
in the process remains. A read of a generation whose grants were given back reaches none of its files (2), so what
may read a generation again holds its grants while the generation stands. A file gone missing and one never
granted are told apart by `open`, not by `stat` (8).
