# Pass-through gate: three trees through the real transfer pipeline, against their source's size and metadata

**Date:** 2026-11-03 · **Host:** M1 Max (MacBookPro18,4, 10 cores), 32 GB, internal SSD (APFS), macOS 27.2 (26B123),
Xcode 27.2 (27B52), on AC · **Load:** 1-minute load average 1.17–2.55 before each run (`uptime`), no other build
or test running

## Summary

1. **Every entry of all three trees lands with its source's metadata, content and decmpfs storage.** For each of
   the 63,348 entries compared across the trees, type, mode, allowed flags, mtime, birth time, size, symlink
   target, allowlisted extended attributes, resource fork and content SHA-256 match the source. Every compressed
   file lands compressed, with the same `com.apple.decmpfs` attribute and the same compressed resource fork bytes.
   That holds in every run, with files sent as LZ4 storage and as plain storage.

   | Tree | Entries (dirs / files / symlinks) | Compressed files, decmpfs types | Storage preserved | Container bytes |
   |---|---|---|---|---|
   | Toolchain `usr/lib` | 7,543 (2,138 / 5,372 / 33) | 4,600: type 4 4,494, type 8 106 | 4,600 | 823,607,357 |
   | SDK `System/Library/Frameworks` | 13,292 (2,278 / 9,642 / 1,372) | 1,814: type 4 1,744, type 8 70 | 1,814 | 59,868,503 |
   | Host `/System/Library/Frameworks` | 42,513 (15,717 / 25,559 / 1,237) | 14,250: type 8 14,013, type 9 237 | 14,250 | 894,974,239 |

   - *What landed compressed:* exactly the source's compressed files. The landed tree's compressed count and type
     histogram equal the source's, by the bench and by an independent survey (`find -flags +compressed` and a C
     program reading each `com.apple.decmpfs` header).
   - *Container bytes* are from the first run. With LZ4 storage, later runs differ by under 1 KB. Each run read a
     fresh `cp -Rc` clone, and a clone takes a new birth time, which changes header lengths. With plain storage the
     containers were 826,002,633, 76,741,494 and 898,066,208 bytes.
   - *The toolchain and SDK trees are no longer all type 4.* Under Xcode 27.2 they also hold type 8 files, so all
     three trees carry fork-based type 8. Type 9, which keeps its bytes in the attribute, appears only in the host's
     tree.

2. **Every tree lands larger on disk than its source, by 2.0–4.6%. All of the excess comes from compressed resource
   forks written in 256 KiB pieces ([#1803](https://github.com/nicholas-lonsinger/kernova/issues/1803)).** On disk
   is `du -sk`, which equalled the summed `st_blocks` of every entry in every run. Wall times are medians of three
   runs with LZ4 storage, and the last column is the one run with plain storage.

   | Tree | Source on disk | Landed on disk | Difference | #1803 excess | Without it | Wall (sender / receiver) | Plain storage wall |
   |---|---|---|---|---|---|---|---|
   | Toolchain `usr/lib` | 816,924 KiB | 854,396 KiB | +37,472 KiB (+4.59%) | +37,492 KiB, 100 files | −20 KiB | 4.71 s (3.14 / 1.56) | 4.76 s |
   | SDK `Frameworks` | 96,648 KiB | 98,956 KiB | +2,308 KiB (+2.39%) | +2,324 KiB, 13 files | −16 KiB | 3.97 s (2.54 / 1.44) | 3.89 s |
   | Host `/System/Library/Frameworks` | 955,680 KiB | 974,788 KiB | +19,108 KiB (+2.00%) | +19,388 KiB, 97 files | −280 KiB | 14.86 s (8.81 / 5.94) | 14.65 s |

   - *The landed sizes repeat exactly.* All three runs of each tree, and the plain-storage run, landed at the
     same KiB.
   - *Which files grow:* only compressed files whose fork exceeds one 256 KiB chunk, and not all of them: 100 of the
     toolchain's 372 such files, 13 of the SDK's 25, and 97 of the host tree's 238. The toolchain's are 76 type 4 and
     24 type 8, the others' all type 8. Their forks run from 263,251 to 68,457,260 bytes. The largest growth is
     `lib_InternalSwiftScan.dylib`'s 68 MB fork, 133,712 blocks to 166,400; a 1.6 MB fork goes from 3,088 to 5,120.
   - *Attribution:* a C program recreated the storage of every compressed file with a fork over one chunk three ways,
     from the source clones, summing `st_blocks` after `sync`:

     | Tree | Fork written whole | In 256 KiB positional pieces | One byte at the fork's last offset first, then the pieces |
     |---|---|---|---|
     | Toolchain `usr/lib` | +0 KiB | +37,492 KiB, 100 files | +0 KiB |
     | SDK `Frameworks` | +0 KiB | +2,324 KiB, 13 files | +0 KiB |
     | Host `/System/Library/Frameworks` | +0 KiB | +19,388 KiB, 97 files | +0 KiB |

     The pieces' excess equals the excess of the files that grew in the transfer, to the KiB and to the file count.
     The pre-extension leaves no file larger than its source on any tree.
   - *What lands smaller:* 5, 4 and 3 files land under their source, by 20, 16 and 280 KiB in all. On the
     toolchain and SDK trees they are compressed files with forks under one chunk, 8 blocks under each. On the host
     tree they are uncompressed model weights. The earlier probe's pass-through receiver landed the same two research trees 20 and 16 KiB
     under source ([the costs note](2026-10-26-decmpfs-pass-through-costs.md), finding 1).

3. **The gate's size condition fails on every tree; its fidelity condition passes on every tree.** Without the
   #1803 pre-extension, the toolchain tree misses by +37,472 KiB, the SDK tree by +2,308 KiB and the host tree by
   +19,108 KiB. The rest of each landing is 20, 16 and 280 KiB under its source, inside the probe's tolerance
   (785,688 against 785,708 KiB on the toolchain tree). So the size condition fails only on the resource-fork
   allocation. The pre-extension recovers the forks' blocks exactly in the attribution probe; the pipeline has
   not been run with it.

## Method

**Bench.** `kernova-bench tree <source> <destination>`, the `KernovaBench` target in `KernovaKit`, built with
`swift build -c release --product kernova-bench` (Xcode 27.2's toolchain) at the commit that adds this note.

- *Pipeline, in one process:* `TreeReader` → `ContainerEncodePipeline` → the container's bytes → `TreeReceiver`,
  which runs `ContainerDecodePipeline` into `TreeWriter` and publishes the item under its own name.
  - Each event's encoded bytes go to the receiver as they are produced, on the caller's thread, with the pipelines'
    lanes beside it.
  - *Sender time* covers `TreeReader.next()` and `encode`. *Receiver time* covers `receive` and `finish`. Wall is
    the whole transfer.
- *Acceptance:*
  - `DecmpfsMatrix.acceptedTypes(landingIn:on:)` for the destination answered types 3, 4, 7–9 and 11–16, so every
    type in the trees was accepted.
  - The pull lists LZ4. `--compression policy` sends as `TransferCompression.forSending(.guestToHost, …)` chooses
    on this host's 10 cores: files as LZ4 storage, 8 encoding lanes. `--compression none` sends every file plain.
  - The receiver decodes on 4 lanes (`TransferCompression.decodingWorkers`).
- *Fidelity:* after the transfer, the bench walks the source and the landed tree side by side, entry by entry.
  - Each directory's names must match.
  - Per entry it compares type, permission bits, the flags in `ValidatedEntry.allowedDarwinFlags`, mtime, birth time,
    allowlisted extended attributes, and, for a symlink, its target.
  - Per regular file it compares size, the SHA-256 of a full read, and the resource fork as the file shows it.
  - Per compressed file it compares the `com.apple.decmpfs` attribute and the resource fork read with
    `XATTR_SHOWCOMPRESSION`. It also counts a compressed file of an accepted type that landed plain, or an
    uncompressed file that landed compressed, as a mismatch.
- *On disk:* the bench sums `st_blocks` over every entry of both trees and lists the files whose counts differ. The
  run script also took `du -sk` of both.

**Trees.**

- *Toolchain `usr/lib`* and *SDK `System/Library/Frameworks`:* the research trees of the costs note, finding 1,
  taken from this host's Xcode 27.2 rather than 27.1. Each is cloned with `cp -Rc` into the session's scratch
  directory, and the clone equals the original in entries, compressed files, types and `du -sk`.
- *Host `/System/Library/Frameworks`:* the type 8/9 tree.
  - `ditto` refuses it. Every entry carries `SF_RESTRICTED`, which an unprivileged copy cannot set, so ditto
    fails each directory with `EPERM`. `cp -R` lands it decompressed. And `cp -c` cannot clone across volumes.
  - It was cloned instead by a C program. That program walks it with `fts`, makes directories and symlinks, copies
    uncompressed files' bytes, and recreates each compressed file from its `com.apple.ResourceFork` (written
    whole, in one `fsetxattr`) and `com.apple.decmpfs`, both with `XATTR_SHOWCOMPRESSION`, then `UF_COMPRESSED`.
    It copies every other extended attribute, the settable user flags, mode, mtime and birth time.
  - The clone matches the original in entries, files, compressed files and type histogram, and in summed
    `st_blocks` (955,680 KiB). `du -sk` of the original reads 942,944 KiB because it counts hard-linked files
    once; the clone holds each as its own file, as the transfer does.
- *Every run* re-cloned its source with `cp -Rc` from the clone above, so the reader read a data fork no earlier run
  had cached. `sync` and a 2 s pause preceded it, and the landing and the run's clone were removed after it.

**Runs.** Three rounds with LZ4 storage, each round the three trees in order, then one round with plain storage.
The load before each was 1.17, 1.18, 2.05; 2.19, 2.39, 2.55; 2.35, 2.07, 1.99; and 2.12, 1.99, 2.01 for the plain
round.

**Attribution probe.** For each compressed file of a source clone whose resource fork exceeds 262,144 bytes
(`ContainerEncoder.chunkByteCount`), a C program read its attribute and fork, then created a new file three ways in
the same scratch volume. Each way set the fork, then the attribute, then `UF_COMPRESSED`:

- the fork in one `fsetxattr`;
- the fork in 262,144-byte `fsetxattr` calls at increasing positions, as `CompressedFile.appendResourceFork` writes
  it;
- one byte at the fork's last offset, then the same pieces.

After `sync` it read `st_blocks` and removed the file.
