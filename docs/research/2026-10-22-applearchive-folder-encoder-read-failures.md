# AppleArchive's folder encoder on items it cannot read, and a FIFO entry on extract

**Date:** 2026-10-22 · **Hardware:** M1 Max, 32 GB, macOS 27.2 (26B118), Xcode 27.1

## Summary

Measured to decide how a folder transfer names an item it cannot read. Supersedes the
2026-08-14 note's decision that a folder stays on `writeDirectoryContents`.

1. **A file the encoder cannot open ends `writeDirectoryContents` with `ArchiveError.ioError`,
   which names neither the file nor the reason.** A `chmod 000` file inside the tree: the call
   throws `ioError`, and `close()` on the encode stream then throws `ioError` too. The entries
   before it in archive order were already written (3,000,384 bytes of a 6,000,649-byte tree).
   The `selectUsing:` filter receives `searchPruneDirectory`, `searchExclude` and
   `encodeScanning` for every entry and never `encodeWriting` — not for a 3 MB or a 200 MB
   file — so no message marks the entry being written when the failure lands.
2. **A directory the encoder cannot list is archived as an empty directory, and the encode
   succeeds.** A `chmod 000` subdirectory: with no filter, `writeDirectoryContents` returns
   normally, and the archive holds the directory's own entry (mode `000`) and nothing under it.
   With a filter, it receives `searchFail` for that path — twice — and the encode still
   succeeds when the filter answers `.ok`.
3. **A tree walked by the caller, writing each entry itself, produces the same archive.** For a
   directory, a symlink or a FIFO, `ArchiveHeader(keySet:directory:path:flags:)` with the
   transfer key set (`TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,CTM`) gives the entry
   `writeDirectoryContents` writes, root (`path: ""`) included; a regular file's header built
   from `fstat` with `CTM` before `MTM` matches byte for byte. Over the macOS SDK's
   `System/Library/Frameworks` (13,291 entries, 90 MB) the two encoders' `aa list -v` listings
   hold the same entries with the same fields; only the order differs, the encoder sorting by
   full path and the walk by name within each directory. Encode time, page cache warm, LZ4 to a
   counting sink: 0.516 s vs 0.524 s there, and 0.800 s vs 0.792 s over the toolchain's
   `usr/lib` (7,479 entries, 767 MB).
4. **`extractStream` parks forever after creating a FIFO entry.** Extracting an archive whose
   tree holds a FIFO — from either encoder — creates the FIFO and then never returns from
   `ArchiveStream.process`; the extract was still parked when killed after 10 s.

## Method

Standalone Swift scripts (`import AppleArchive; import System`) built with `swiftc -O` and run
from a terminal, no sandbox. The encode probes wrote to an `ArchiveByteStream.fileStream` or a
counting `ArchiveByteStreamProtocol` sink through an LZ4 compression stream, logging every
`selectUsing:` message with its path. Archives were compared with `cmp` and with
`aa list -v -i`, with and without the timestamp fields, sorted and in archive order. The walk
used `lstat`, `opendir`/`readdir` with names sorted, `open(O_RDONLY | O_NOFOLLOW)` and `fstat`
for regular files, and `writeHeader` plus `writeBlob(key: "DAT")` in 4 MiB reads. The FIFO
extract ran `ArchiveStream.process` from a decode stream into `extractStream(extractingTo:flags:
.ignoreOperationNotPermitted)` under `timeout 10`.
