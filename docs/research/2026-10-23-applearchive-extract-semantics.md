# What AppleArchive's `extractStream` does with each entry and attribute, and FileManager on deep trees

**Date:** 2026-10-23 · **Hardware:** M1 Max (MacBookPro18,4), 32 GB, macOS 27.2 (26B118), Xcode 27.1 (27A9275)

## Summary

These measurements describe what a replacement for the receiver's extract must match or deliberately change. Every
extract ran in the receiver's configuration: `extractStream(extractingTo:selectUsing:flags: .ignoreOperationNotPermitted)`
with a filter that clears `UF_IMMUTABLE|SF_IMMUTABLE|UF_APPEND|SF_APPEND` from `attributes.flg` and returns `.ok`, fed by
`ArchiveStream.process(readingFrom: decodeStream, writingTo:)`. Entries carried the fields of `ClipboardArchive.fieldKeys`
in that order.

1. **A failure surfaces in one of three ways, and none of them names a path in the thrown error.**
   - *Entry failure:* the filter receives `extractFail` with the entry's path. `process` returns normally, the later
     entries are extracted, and only `close()` on the extract stream throws `ArchiveError.ioError`.
   - *Rejected header:* the decoder refuses the entry (finding 9). `process` throws `ArchiveError.ioError`, no later
     entry is extracted, and `close()` throws `ioError` too.
   - *Silent:* nothing is thrown and the filter receives no failure message (findings 2, 5, 6, 8).

   The extract runs on worker threads (`extractThreadProc`), and filter messages arrive out of archive order. Each entry
   also produces a message with raw value 27, which `AAEntryMessage.h` does not define, carrying no data.
2. **An entry whose `PAT` is 1,024 bytes or more is skipped without a trace.** It gets no filter message at all, and
   `process` and `close()` both succeed. The decoder still delivers it: `readHeader` returns the header and its `DAT`.
   A 1,023-byte `PAT` reaches the extractor. An entry with a shorter `PAT` whose absolute destination path exceeds
   `PATH_MAX` is an entry failure (finding 1). This is the case for six 200-byte directories under a 208-byte
   destination: the fifth directory (1,213 bytes) fails, and the sixth directory and its file (1,205- and 1,214-byte
   `PAT`) are skipped. A relative destination fails at the same entry, so the limit applies to the absolute path.
   Parents created implicitly for a failing entry stay on disk, as deep as the path fits. A 256-byte component is also
   an entry failure, whether it is 256 ASCII bytes or 256 × U+00E9. APFS takes a name of up to 255 UTF-16 units:
   `mkdirat` accepts 255 × U+00E9 (510 bytes) and 127 × U+1F600 (254 units), and returns `ENAMETOOLONG` for 256 ASCII
   bytes, 256 × U+00E9, and 128 × U+1F600.
3. **APFS refuses a name that is not UTF-8, and the Swift header API substitutes U+FFFD for it, but the C API
   returns the raw bytes.**
   - *Extract:* a file `caf\xE9.txt` is an entry failure. A directory `dir\xE9` fails, and so does its child. The
     filter's `FilePath` carries the raw `\xE9`.
   - *APFS:* `mkdirat`, `openat(O_CREAT)`, `mkfifoat` and the name argument of `symlinkat` each return `EILSEQ` for the
     name. A symlink *target* holding `\xE9` is stored unchanged. APFS here is also case- and normalization-insensitive:
     creating the NFD spelling of an existing NFC name with `O_EXCL` returns `EEXIST`.
   - *Swift API:* `ArchiveHeader.field(forKey: "PAT")` returns the string `caf\u{FFFD}.txt`
     (`63 61 66 EF BF BD 2E 74 78 74`). It does this for a header built through `init?(withAAEncodedData:)`, for one
     returned by `decodeStream.readHeader()`, and for the filter's `.header` data.
   - *C API:* `withAAEncodedData` → `AAHeaderCreateWithEncodedData` → `AAHeaderGetFieldString` returns
     `63 61 66 E9 2E 74 78 74` exactly. So does the inline `AAHeaderGetFieldStringWithKey`, which returns status 1
     (found). Under `import AppleArchive` these C functions are visible from Swift by their `swift_private` names
     (`__AAHeaderCreate`, `__AAHeaderGetFieldString`, `__AAFieldKey` with its `ikey` member). The link needs
     `-lAppleArchive`: without it the link fails with `_AAHeaderCreate` undefined, because the Swift module does not
     autolink the C library.
4. **A socket, character-device or block-device entry is an entry failure, and nothing is created.** The cases are
   `TYP=S`, `TYP=C` with `DEV=0x3000002`, and `TYP=B` with `DEV=0x1000000`. The surrounding entries extract, and
   `.ignoreOperationNotPermitted` does not absorb the failure. Unprivileged, `mknodat` returns `EPERM` for `S_IFCHR`,
   `S_IFBLK` and `S_IFSOCK`, and succeeds for `S_IFIFO`.
5. **`FLG` lands on files, directories and symlinks alike. A flag the receiver may not set silently costs the entry
   its other attributes.**
   - *Flags that land:* `UF_NODUMP`, `UF_OPAQUE`, `UF_TRACKED` and `UF_HIDDEN` land on all three entry types.
   - *Flags the filter clears:* the immutable and append bits arrive cleared, and every other attribute is applied.
   - *`UF_COMPRESSED`:* it lands on a regular file only, not on a directory or a symlink. `ls -lO` shows `compressed`,
     and the file still reads back its bytes.
   - *`SF_DATALESS`:* it is dropped, and the rest of the entry's attributes are applied.
   - *Flags that cost the other attributes:* `UF_DATAVAULT`, `SF_ARCHIVED`, `SF_RESTRICTED`, `SF_NOUNLINK` and
     `SF_FIRMLINK` are not set. In addition, a regular file or symlink carrying one keeps its creation mode (0644 or
     0755 under umask 022), the group it inherited, and the current time as both `st_mtimespec` and
     `st_birthtimespec`. A directory carrying one gets its `GID` but not its mode or times. There is no failure
     message, and `process` and `close()` both succeed.

   No `FLG` value made an extract fail.
6. **Modes are applied after a directory's contents, setuid and setgid survive, and the root entry's attributes land
   on the destination directory itself.**
   - *Special bits:* modes 4755, 2755, sticky on a file (1644), and 1777 on a directory are applied as written.
   - *Read-only directories:* a directory with mode 0555 or 0000 followed by entries inside it extracts completely,
     and the directory ends with its mode.
   - *Root entry:* the entry with an empty `PAT` sets the destination directory's mode (0750), `UF_HIDDEN`, mtime and
     birth time.
   - *Silent loss on chmod:* a setgid entry whose `GID` the receiver is not in loses its mode and times without trace.
     For `me-g1-2750`, the chown is refused, and the file keeps group 0 (inherited, not one of the receiver's groups),
     mode 0644 and the current times. The same entry without setgid (`me-g1-0750`) keeps mode 0750 and its times.
7. **Ownership the receiver cannot give is absorbed: the file keeps the receiver's uid and the group it was created
   with.** This holds for `UID` 0, `UID` 502 and `GID` 0 or 1 (groups the receiver is not in), on files, directories
   and symlinks. The entry's mode and times are still applied. A `GID` the receiver belongs to (20, 204) is applied.
   A created entry inherits its parent directory's group at creation time, and that happens before the root entry's
   attributes are applied: the destination was created with gid 0, so every child whose group could not be set has
   gid 0. A setuid entry owned by uid 0 or 502 extracts as mode 4750, owned by the receiver.
8. **`MTM` and `CTM` land as mtime and birth time on files, directories, symlinks and the root.** A directory's times
   are applied after its children, so the mtime survives files created inside it later. A symlink gets its own times,
   not its target's.

   A FIFO entry creates the FIFO, and then `applyEntryAttributes` blocks in `open()` on it, so the FIFO's times are
   never applied. In this run (a four-entry archive) `ArchiveStream.process` returned. What parked is
   `AAArchiveStreamClose`, waiting for that worker; it was still parked when killed after 10 s.

   Parents that no entry names are created on demand, with mode 0755 under umask 022, the receiver's uid, the
   inherited group and the current times, and those times are never set afterwards.
9. **Duplicate and case-colliding paths race, and the result varies from run to run, including mixed bytes.**
   Outcomes over 200 runs of each archive:

   | Archive | Outcome | Runs |
   |---|---|---|
   | `dup.txt` = `first`, then `dup.txt` = `second` | `second` | 165 |
   | | `first` | 23 |
   | | `firstd` (`first` written over `second` without truncation) | 12 |
   | `Readme` = `lower`, then `README` = `UPPER` | `Readme` holding `UPPER` | 153 |
   | | `README` holding `lower` | 30 |
   | | `Readme` holding `lower` | 15 |
   | | `README` holding `UPPER` | 2 |

   In every one of those runs `process` and `close()` succeeded, with no failure message.

   A file followed by a directory of the same name (50 runs): in 45 the file stayed, and the directory and its child
   were entry failures. In 5 the directory and its child won. A directory followed by a file of the same name: the
   directory and child stayed and the file failed, in 50 of 50 runs. The same directory twice merges, and both
   children are present.
10. **The decoder rejects `..`, `.` and absolute paths. A symlink pointing outside the destination is created, but
    nothing is written through it.** A `PAT` of `../escape.txt`, `sub/../../escape2.txt`, `./dot/./b.txt` or an
    absolute path makes `readHeader` throw `ioError`, so that entry is a rejected header (finding 1). Entries before it
    are extracted, and nothing is created outside. A symlink entry `l → <absolute path outside>` or `r → ../outside`
    is created with that target. The following entry `l/x.txt` or `r/y.txt` is an entry failure, and the outside
    directory stays empty.
11. **Unprivileged on APFS, `setattrlistat` sets flags, birth time, mtime and mode on every entry type without
    following or opening it. `fchownat` succeeds only for the receiver's own uid and its groups.**
    - *`setattrlistat(dirfd, name, …, FSOPT_NOFOLLOW)`:* it succeeds on a regular file, a directory, a symlink (applied
      to the link itself) and a FIFO (it returns at once, and the FIFO is not opened). This holds for `ATTR_CMN_FLAGS`,
      `ATTR_CMN_CRTIME`, `ATTR_CMN_MODTIME` and `ATTR_CMN_ACCESSMASK`, each alone and all four in one call. In the
      combined call the buffer holds CRTIME, MODTIME, ACCESSMASK, FLAGS, in that order.
    - *Flags through `ATTR_CMN_FLAGS`:* `UF_NODUMP`, `UF_IMMUTABLE`, `UF_APPEND`, `UF_OPAQUE`, `UF_TRACKED` and
      `UF_HIDDEN` are set. `UF_DATAVAULT` and every `SF_` flag (`ARCHIVED`, `IMMUTABLE`, `APPEND`, `RESTRICTED`,
      `NOUNLINK`, `FIRMLINK`) return `EPERM`. `UF_COMPRESSED` and `SF_DATALESS` return 0 and are not set.
    - *`fchownat(…, AT_SYMLINK_NOFOLLOW)`:* it returns `EPERM` for uid 502 or 0, and for the receiver's uid with gid 0
      or 1. It succeeds with gid 20 or 204, on a file and on a symlink.
    - *Name length:* `mkdirat` and `openat(O_CREAT)` accept a 255-byte name and return `ENAMETOOLONG` for a 256-byte
      one.
12. **`FileManager.removeItem` and `removefile(3)` remove nothing from a tree that is too deep or holds a directory
    the caller cannot write.** `removeItem`'s error names only the root passed in, and `removefile` reports only an
    errno.
    - *Paths over `PATH_MAX`:* a tree of seven 200-byte directory levels, each holding a file (deepest path 1,620
      bytes). `removeItem` throws `NSCocoaErrorDomain` 514 (`NSFileWriteInvalidFileNameError`) with underlying
      `NSPOSIXErrorDomain` 63 (`ENAMETOOLONG`). `removefile(REMOVEFILE_RECURSIVE)` returns −1 with `ENAMETOOLONG`.
      Both leave all 14 entries, including the files at depths that fit.
    - *A 0555 directory holding files and a subdirectory:* `removeItem` throws 513 with underlying POSIX 13
      (`EACCES`), and `removefile` returns −1 with `EACCES`. All four entries remain.
    - *A 0000 directory, empty or holding a file:* the same 513 / `EACCES`, and the directory remains.
    - *Control:* a 0000 file in a writable directory is removed by both.
13. **`FileManager.moveItem` moves a tree deeper than `PATH_MAX` within a volume, but not across volumes.**
    - *Within a volume:* it succeeds, and the whole tree arrives.
    - *Onto another APFS volume:* a two-level tree moves. The seven-level tree (deepest path 1,625 bytes) throws
      `NSCocoaErrorDomain` 514, with underlying `NSCocoaErrorDomain` 514 and `NSFilePathErrorKey` set to the source
      root. The source is left intact (14 entries), and nothing is left at the destination.

## Method

Standalone Swift scripts (`import AppleArchive; import System`) built with `swiftc -O … -lAppleArchive` and run from a
terminal: no sandbox, no `sudo`, account uid 501. The account's primary group is 20, and it is a member of 204 but not
of 0 or 1. Shell umask was 022. Everything ran on the internal APFS Data volume, under a scratch directory whose group
is wheel (gid 0), so the probe's directories and files were created with gid 0.

Each probe archive was hand-built. Each entry's header was made through the C API (`__AAHeaderCreate`,
`__AAHeaderSetFieldUInt/String/Timespec/Blob`, appended at index `UINT32_MAX`), in the order
`TYP,PAT,LNK,DEV,UID,GID,MOD,FLG,CTM,MTM,DAT`, so string fields could carry raw bytes. The encoded header was turned
into an `ArchiveHeader(withAAEncodedData:)` and written through `ArchiveStream.encodeStream` over an LZ4
`compressionStream` to a file, with `writeBlob(key: "DAT")` for file contents. Default attributes were the receiver's
uid/gid, `CTM` 981173106.111111111 and `MTM` 1013000000.222222222. The extract read the file through
`decompressionStream` and `decodeStream` into the `extractStream` configuration in the Summary, with the destination
an existing 0755 directory at an absolute path of 207–211 bytes. Every filter message was logged with its path's raw
bytes and any `EntryAttributes`. Afterwards the streams were closed in the receiver's order: extract, decode,
decompress, read.

The result was read through descriptors with `openat`/`fdopendir`/`fstatat(AT_SYMLINK_NOFOLLOW)`: type, mode, uid,
gid, `st_flags`, size, `st_mtimespec` and `st_birthtimespec`, plus `readlinkat` for symlinks and the first bytes of
each file. Decoder behavior was checked separately with a `readHeader`/`readBlob` loop over the same archive. The
FIFO archive ran under `timeout 10`, and a second run was `sample`d after 2 s for the stacks. The duplicate-path
archives were each extracted 200 times (50 for the file/directory pairs) into a fresh destination, and the outcomes
were tallied.

The syscall probes called `mknodat`, `mkfifoat`, `mkdirat`, `openat` and `symlinkat` directly. They called
`setattrlistat` with `FSOPT_NOFOLLOW` and an `attrlist` naming one or all four common attributes, and `fchownat` with
`AT_SYMLINK_NOFOLLOW`, then read the result back with `fstatat`.

The trees for removal and move were built with `mkdirat` and `openat`: seven nested 200-byte directory names, each
directory holding a one-byte `f.txt`. The two-level control was built the same way. Each removal ran on a fresh tree,
and each tree that remained was counted, and then removed level by level through descriptors (`fchmodat`,
`setattrlistat` to clear flags, `unlinkat`). The second volume was a disk image made with
`hdiutil create -size 64m -fs APFS -volname KernovaProbe` and `hdiutil attach -nobrowse -mountpoint`, then detached
and deleted.
