# The sandbox grants a pasteboard read takes, giving them back, and bookmarks made under them

**Date:** 2026-11-18 · **Host:** macOS 27.2.1 (26B131), command-line probes

## Question

When a sandboxed process reads a file URL off a pasteboard, which reads take a grant of access to the file, what
does giving one back with `stopAccessingSecurityScopedResource()` take away, what does it do to a grant of the
same path that a security-scoped bookmark holds, and can a bookmark made under the grant reach the file once the
grant is given back?

## Method

Two probes the same day, each an unsandboxed writer and a reader ad-hoc signed with
`com.apple.security.app-sandbox` and `com.apple.security.files.bookmarks.app-scope`, the reader running a script
of steps in one process and the writer writing a new pasteboard generation between steps where a step says so.

The first wrote `NSURL`s of files and folders to a private named pasteboard (`NSPasteboard(name:)`), one item per
URL, every name the same length. The second wrote as Finder does, each item's `public.file-url` a file reference
URL (`file:///.file/id=…`) beside its name and icon types. The readers' steps:

- read items' `public.file-url` by `string(forType:)`, by `data(forType:)`, or by
  `readObjects(forClasses: [NSURL.self])`, from the items of an earlier fetch or a fresh `pasteboardItems`;
- `open(2)` each path read, which fails `EPERM` without a grant, and read its `lstat(2)` and resource values;
- call `stopAccessingSecurityScopedResource()` on `URL(fileURLWithPath:)` of a path;
- make a security-scoped bookmark of a path while it was granted, with `.withSecurityScope` alone or with
  `.securityScopeAllowOnlyReadAccess` too, of files mode 0444 or user-immutable (`chflags uchg`) among others;
  resolve it, and start or stop its access;
- read every item's `types`, `canReadObject(forClasses: [NSURL.self])` and
  `readObjects(forClasses: [NSFilePromiseReceiver.self])`;
- between steps, from outside the sandbox, move or rename the granted files, or move their folder, and move them
  back;
- meter the grants left: read fresh files until the first `open` fails;
- time, per item of 100, 1,000 and 5,000 files: read its URL, bookmark it, give the grant back; then resolve each
  bookmark, start it, open the file and stop.

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
8. A path without a grant still answers `lstat(2)`, `FileManager.fileExists(atPath:)` and its content type,
   whether it is a directory and its size; `open` fails.
9. A grant stays with its path, not its file: a granted file moved away did not open at its new path. A give-back at
   the old path, made while the file was away, took the grant as long as the old path's folder still existed; with
   that folder itself moved away, a give-back at the old path or the new one took nothing, and moved back, every file
   opened, and a give-back then closed it.
10. A give-back of a path holding no grant, even three in a row, left no debt: the next generation's read of the
    path took its grant and opened it.
11. A give-back through a file's reference URL (`file:///.file/id=…`) took its grant while the file was at its path.
12. A security-scoped bookmark made while the read's grant lasted outlived the grant: with the grant given back,
    `open` failed; with the file, or its folder, moved and renamed, the bookmark resolved to the new path, stale,
    its access started, the file opened, and so did a file inside the moved folder; its stop closed them again.
    Only the first reads took pasteboard grants.
13. Read through a Finder copy's reference URL, `public.file-url` named the file's path at the time of the read.
    Once the pasteboard moved to a new generation, items fetched before it had no types and named nothing.
14. Per item, reading the URL took 0.4 to 0.6 ms, making the bookmark (`.withSecurityScope`) 1.0 to 1.2 ms and
    giving the grant back 0.02 to 0.03 ms; resolving, starting, opening and stopping took 0.5 to 0.65 ms. 5,000
    files took 2.0 s to read, 4.8 s to bookmark and 2.6 s to resolve, start, open and stop, cycling one grant at a
    time.
15. Under a pasteboard grant that opened them, a bookmark with `.withSecurityScope` alone failed for the files mode
    0444 and the user-immutable one, `NSCocoaErrorDomain` 256, "Could not open() the item", and was made for the
    rest. With `.securityScopeAllowOnlyReadAccess` added, it was made for every file; resolved and started, it
    opened each for reading, and stopped, closed it again.
16. A read-only bookmark's started grant and a pasteboard grant of the same path counted as two. For 400 files
    holding both the meter read 656 files, 800 fewer; with both given back it read 1,456, and making the bookmarks
    alone cost none. Given back in either order, a path stayed open until the second went.

## Consequence

A grant a pasteboard read took is given back exactly once, and only by what recorded taking it, since a give-back
for a read that took nothing takes a grant another holder of the path took. Which reads took one is decided by
the first read of each item in a generation, so every read of a generation shares one record of them. Nothing
answers whether a read took a grant (5), so a pasteboard read's give-back waits until no other holder of the path
in the process remains. A read of a generation whose grants were given back reaches none of its files (2) but a
bookmark made under them does, wherever the file has moved (12), so a read that keeps its files past its grants
keeps them as bookmarks, and every read of the generation shares those too. Without a grant a file's metadata
still reads, but only `open` tells a file never granted from one gone missing (8). A grant whose path's folder has
moved away is given back by nothing (9); a give-back that takes nothing costs nothing later (10). A bookmark asking
for read-write access refuses a file the process can only read, and one asking for read alone does not (15); its
grant counts and is given back like any other (16).
