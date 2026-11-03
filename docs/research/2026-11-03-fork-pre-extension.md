# Fork pre-extension: the pass-through gate's three trees land at their source's size

**Date:** 2026-11-03 · **Host:** M1 Max (MacBookPro18,4, 10 cores), 32 GB, internal SSD (APFS), macOS 27.2 (26B123),
Xcode 27.2 (27B52), on AC · **Load:** 1-minute load average 51–298 before each run (`uptime`), from other work on
the host; wall times below are therefore not comparable with the gate note's

Supersedes finding 3 of [the gate note](2026-11-03-pass-through-gate.md): with each resource fork extended to its
length before its pieces are written (`ResourceForkWriter`), the gate's size condition holds on every tree.

## Summary

1. **No file lands larger than its source, on any tree.** The receiver that writes one zero byte at each fork's last
   offset before its 256 KiB pieces lands every tree at or under its source's summed `st_blocks`; the receiver
   without it repeats the gate note's excess to the KiB and to the file.

   | Tree | Source on disk | Landed, without the pre-extension | Landed, with it | Files grown, without / with |
   |---|---|---|---|---|
   | Toolchain `usr/lib` | 816,924 KiB | 854,396 KiB (+37,472, +4.59%) | 816,904 KiB (−20) | 100 (+37,492 KiB) / 0 |
   | SDK `Frameworks` | 96,648 KiB | 98,956 KiB (+2,308, +2.39%) | 96,632 KiB (−16) | 13 (+2,324 KiB) / 0 |
   | Host `/System/Library/Frameworks` | 955,680 KiB | 974,788 KiB (+19,108, +2.00%) | 955,400 KiB (−280) | 97 (+19,388 KiB) / 0 |

   - *Repeatable:* two runs with LZ4 storage and one with plain storage landed each tree at the same KiB.
   - *Fidelity unchanged:* in every run, every entry matched its source in type, mode, allowed flags, compression,
     mtime, birth time, size, symlink target, allowlisted extended attributes, resource fork, content SHA-256 and
     decmpfs storage, and every compressed file (4,600, 1,814 and 14,250) landed with its source's attribute and
     compressed fork bytes.

2. **What remains under source is not the transfer's.** The same 5, 4 and 3 files land under their source by 20, 16
   and 280 KiB with and without the pre-extension, as in the gate note. On the toolchain tree they are compressed
   files whose forks fit one piece; a C program that recreated two of them with the fork in one `fsetxattr` got the
   same counts as the landing (139,261-byte fork: source 280 blocks, whole write 272; 12,288-byte fork: 32 and 24),
   so the source holds one 4 KiB block a fresh write does not take. On the SDK tree they are four headers, 16 blocks
   to 8; on the host tree, three uncompressed model-weight files.

## Method

**Bench.** `kernova-bench tree <source> <destination>` (the `KernovaBench` target in `KernovaKit`), built with
`swift build -c release --product kernova-bench`, at two commits: `origin/main` before this note's change, and the
commit that adds `ResourceForkWriter`. Pipeline, acceptance, fidelity comparison and on-disk sums are the gate note's.
`du -sk` of source and landing was also taken; it equalled the summed `st_blocks` in every run but one, the host
tree's landing without the pre-extension (974,736 against 974,788 KiB).

**Trees.** The gate note's three, built the same way:

- Toolchain `usr/lib` and SDK `System/Library/Frameworks` from this host's Xcode 27.2, cloned with `cp -Rc`: 7,543
  and 13,292 entries, 816,924 and 96,648 KiB, as in the gate note.
- Host `/System/Library/Frameworks` cloned by a C program that walks it with `fts`, copies plain files' bytes, and
  recreates each compressed file from its `com.apple.ResourceFork` (one `fsetxattr`) and `com.apple.decmpfs`, both
  read with `XATTR_SHOWCOMPRESSION`, then `UF_COMPRESSED`, with the other extended attributes, settable flags, mode,
  mtime and birth time: 42,513 entries and 955,680 KiB summed `st_blocks`, equal to the original and to the gate
  note's clone.

**Runs.** Each run re-cloned its tree with `cp -Rc`, then `sync` and a 2 s pause; the landing and the run's clone
were removed after it. One round without the pre-extension with LZ4 storage (`--compression policy`), then with it
two rounds with LZ4 storage and one with plain storage (`--compression none`), each round the three trees in order.

**Pre-extension alone.** A C program wrote forks of 300,000, 1,500,000 and 5,000,000 bytes into new files in
262,144-byte positional `fsetxattr` calls, with and without one byte at the last offset first, and wrote the same
forks in one call. It read the fork's `st_blocks` (`..namedfork/rsrc`) straight after the writes, after `fsync`, and
after `sync`; all three reads agreed. Whole: 592, 2,936, 9,768 blocks; pieces alone: 640, 2,936, 11,776; one byte
first, then the pieces: 592, 2,936, 9,768.
