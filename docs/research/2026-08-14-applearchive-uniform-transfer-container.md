# AppleArchive as the uniform transfer container: single-entry encoding, LZ4, page cache

**Date:** 2026-08-14 · **Hardware:** M1 Max, 32 GB, macOS 27.0, Xcode 27 beta SDK ·
**Tracking issues:** #862 (design), #857 (read policy)

## Summary

Measurements taken to design #862 — every file, folder and oversize inline payload crossing the
wire as one AppleArchive stream — and to settle #857's residual question of how the archive's
source reads should treat the page cache.

1. **A single file cannot be archived through `writeDirectoryContents(archiveFrom:path:)`.**
   `path:` naming a regular file throws `ArchiveError.ioError` unconditionally (custom or default
   key set, relative or absolute path, `.ignoreOperationNotPermitted`, verbosity flags — the
   `selectUsing:` filter is never invoked). `path:` naming a *directory* works and is scoped: no
   ancestor entries, no root entry, and no sibling scan (0.6 ms with 20,000 siblings present vs
   540 ms for the whole directory). `archiveFrom:` the file itself yields one `regularFile` entry
   with an empty `PAT`, which `extractStream` refuses. So a one-entry archive is hand-built:
   `ArchiveHeader()` with `TYP`, `PAT`, `UID`, `GID`, `MOD`, `FLG`, `MTM`, `CTM` from `stat` and a
   `DAT` blob of the declared size, then `writeBlob(key:from:)` in 4 MiB pieces — `writeBlob` may
   be called repeatedly for one blob. An unmodified `extractStream` reproduces the file
   byte-identically with mode, `st_flags` and nanosecond mtime intact. `ArchiveHeader.FieldKey` has
   only `init(_ String)`; `EntryType.rawValue` is `UInt32`.
2. **LZ4 encodes 5–7× faster than LZFSE for ~60 % of its ratio on realistic text, and identically
   on incompressible or mixed data.** 1 GiB, page-cache-warm source, output to a counting sink:

   | payload | codec | ratio | wall | MiB/s | CPU |
   |---|---|---|---|---|---|
   | urandom | lz4 | 1.000 | 0.130 s | 7,883 | 0.99 s |
   | urandom | lzfse | 1.000 | 0.646 s | 1,586 | 5.45 s |
   | random dictionary words | lz4 | 1.28 | 0.299 s | 3,423 | 2.59 s |
   | random dictionary words | lzfse | 2.09 | 2.12 s | 484 | 19.1 s |
   | 50 % text / 50 % random | lz4 | 1.99 | 0.128 s | 8,004 | 0.58 s |
   | 50 % text / 50 % random | lzfse | 1.99 | 0.525 s | 1,948 | 4.12 s |

   Incompressible input grows by 4 KB per 1 GiB (blocks stored raw). `blockSize` between 256 KiB
   and 4 MiB moves LZ4 throughput by under 5 %. `decompressionStream(readingFrom:)` takes no codec
   argument: the codec is the stream's 4-byte magic (`pbz4` lz4, `pbze` lzfse, `pbzb` lzbitmap,
   `pbzz` zlib), so a receiver decodes any of them blind.
3. **The encoder reads through the unified buffer cache; the extractor writes around it.** After
   archiving a 1 GiB file whose pages started 0 % resident, 100 % were resident — the same as a
   plain `read()` loop, for lz4 and lzfse alike; `writeDirectoryContents` sets no `F_NOCACHE` on the
   sources it opens and offers no hook to. After `extractStream` wrote a 512 MiB entry, 0 % of its
   pages were resident and the file was fully allocated (not sparse) — the same as a `write()` loop
   on an `F_NOCACHE` descriptor, where a plain `write()` loop leaves 100 % resident. And a `read()`
   loop on an `F_NOCACHE` descriptor in 4 MiB reads still left **75 %** of the file resident
   (stable across three trials, not decaying over 2.5 s): the flag does not deliver the eviction
   protection it is usually kept for.
4. **Neither the decompression nor the decode stream seeks** — zero `seek`/`read(atOffset:)` calls
   over a full directory and single-file round trip through a source whose random-access methods
   throw. `ArchiveHeader.FieldKeySet` parsing is case-insensitive, reorders keys, and returns nil
   for an empty string, an unknown key, or an empty element. `extractStream(extractingTo:)`
   returns nil when the destination directory does not exist.

## Method

Standalone Swift scripts (`import AppleArchive; import System`) built with the Xcode 27 beta
toolchain and run from a terminal, no sandbox, no `sudo`. Page residency was read with
`mincore(2)` over a read-only `mmap` of the whole file (16 KiB pages; a 0 % → 100 % control after
touching every page validated the probe) and cross-checked against `vm_stat` "File-backed pages"
deltas. Files were created with `dd if=/dev/urandom` through an `F_NOCACHE` descriptor so every
trial started cold; the encode-side trials archived to a byte stream that counts and discards.
Encode timing used wall clock plus `getrusage` CPU around the call, best of three, source warm in
the page cache. The `writeDirectoryContents(path:)` behaviors were established by decoding the
resulting archive with `ArchiveStream.decodeStream` and a `readHeader()` loop and by logging the
paths the `selectUsing:` filter was asked about.

## Decisions taken on this evidence

- Every non-inline payload — and an inline one too large to hold resident — crosses as an LZ4
  AppleArchive; a single file is a hand-built one-entry archive (finding 1) read by the app in
  4 MiB blocks; a folder stays on `writeDirectoryContents`.
- Source reads are page-cached uniformly (#857 closed as absorbed): the folder encoder gives no
  read-policy hook, the extract side is already uncached, and `F_NOCACHE` on the single-file read
  would keep at most a quarter of the file out of the cache while forfeiting readahead — the
  serial-read stall #857 measured is what disappears with the raw file path.
