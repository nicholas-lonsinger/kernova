# Receiver writer throughput: `TreeMaterializer` against AppleArchive's `extractStream`

**Date:** 2026-10-24 · **Hardware:** M1 Max (MacBookPro18,4, 10 cores), 32 GB, internal SSD (APFS), macOS 27.2 (26B118), Xcode 27.1 (27A9275), on AC power

## Summary

Four sender archives, each decoded from memory by four writers: `extractStream` as the receiver configured it
(**extractStream**), the same with `UF_COMPRESSED` also cleared in its filter (**extractStream, no decmpfs**),
`TreeMaterializer` (**TreeMaterializer**), and `TreeMaterializer` with its attributes applied in one `setattrlist`
call per entry (**TreeMaterializer, one call**). Median of five runs; wall time covers the extract alone.

| Case | Writer | Wall (s) | User CPU (s) | System CPU (s) | On disk |
|---|---|---|---|---|---|
| 1 GiB incompressible file (2 entries, 1.07 GB) | extractStream | 0.440 | 0.714 | 0.211 | — |
| | extractStream, no decmpfs | 0.432 | 0.707 | 0.208 | — |
| | TreeMaterializer | 0.268 | 0.248 | 0.114 | — |
| | TreeMaterializer, one call | 0.268 | 0.255 | 0.111 | — |
| SDK `System/Library/Frameworks` (13,291 entries, 278 MB of file data) | extractStream | 2.044 | 4.478 | 4.004 | 98 MiB |
| | extractStream, no decmpfs | 0.856 | 0.797 | 3.783 | 288 MiB |
| | TreeMaterializer | 1.883 | 0.201 | 1.752 | 288 MiB |
| | TreeMaterializer, one call | 1.538 | 0.194 | 1.422 | — |
| Toolchain `usr/lib` (7,479 entries, 2.23 GB of file data) | extractStream | 21.328 | 45.822 | 3.773 | 844 MiB |
| | extractStream, no decmpfs | 1.380 | 2.328 | 2.717 | — |
| | TreeMaterializer | 1.663 | 1.010 | 1.360 | 2.09 GiB |
| | TreeMaterializer, one call | 1.405 | 0.982 | 1.111 | — |
| 50,000 files of 1–4 KiB in 551 folders (128 MB) | extractStream | 2.111 | 1.946 | 11.366 | — |
| | extractStream, no decmpfs | 2.122 | 2.048 | 11.325 | — |
| | TreeMaterializer | 6.462 | 0.380 | 6.045 | — |
| | TreeMaterializer, one call | 5.255 | 0.355 | 4.875 | — |

Every run fell within 10 % of its median except six slower ones: the first `TreeMaterializer` run on the 1 GiB
file (0.387 s, +44 %) and five `extractStream` runs (+13 % to +22 %). A `sync()` issued after each extract took
0.06–0.23 s for every writer and case. "On disk" is `du -sk` of one run's output, taken where a dash is absent.

1. **On bulk data `TreeMaterializer` is faster than `extractStream` and stays out of the page cache.** The 1 GiB
   file lands in 0.27 s against 0.44 s, using a third of the CPU. After every run of every writer, 0 of the file's
   65,536 16 KiB pages were resident.
2. **On trees of many entries `TreeMaterializer` is slower in wall time, because it creates entries on one thread
   and `extractStream` on ten.** Against `extractStream` with decmpfs off, it costs 128 µs of wall time per entry
   to `extractStream`'s 42 µs on the 50,000-file tree (3.0×), 2.2× on `System/Library/Frameworks`, and 1.2× on
   `usr/lib`. It spends half the CPU doing it: 6.4 s against 13.4 s on the 50,000-file tree.
   `extractStream` runs one `extractThreadProc` worker per core (10 here), and its workers spend about 225 µs of
   system time per file, against `TreeMaterializer`'s 120 µs.
3. **`TreeMaterializer`'s time on a small-file tree is the kernel's per-entry metadata cost.** Main-thread samples
   on the 50,000-file tree:

   | Call | Share |
   |---|---|
   | `openat(O_CREAT \| O_EXCL)` | 44 % |
   | `fsetattrlist`, four per entry | 27 % |
   | `write` | 8 % |
   | `fchown` | 8 % |
   | `close` | 7 % |
   | decode, header parsing and Swift code | 6 % |

   That is about 56 µs per file created and 8.5 µs per `setattrlist` call. `extractStream`'s workers, sampled on the
   same tree, spend their time in `openat`, `lstat`, `pwrite`, `close`, one `fsetattrlist` per entry, and
   `__psynch_mutexwait`.
4. **Applying the four attributes in one `setattrlist` call saves 24–35 µs per entry.** That is 1.21 s on the
   50,000-file tree, 0.35 s on `System/Library/Frameworks` and 0.26 s on `usr/lib`: 16–19 % of
   `TreeMaterializer`'s wall time on each tree. On the 1 GiB file it saves nothing measurable. With the calls
   merged, the 50,000-file tree still takes 2.5× as long as `extractStream` with decmpfs off.
5. **`extractStream` re-applies APFS transparent compression to every regular file whose `FLG` carries
   `UF_COMPRESSED`, and `TreeMaterializer` lands those files uncompressed.** The sender's archive carries the flag
   on 1,814 of `System/Library/Frameworks`' 9,641 files and 4,574 of `usr/lib`'s 5,325; `extractStream`'s output
   carries it on exactly those files. On `usr/lib` that costs `extractStream` 21.3 s of wall time and 45.8 s of user
   CPU, and its output occupies 844 MiB on disk against `TreeMaterializer`'s 2.09 GiB. On
   `System/Library/Frameworks` the output is 98 MiB against 288 MiB. The file contents are byte-identical either
   way. Clearing `UF_COMPRESSED` in the filter's `extractAttributes` message stops the compression, and then
   `extractStream`'s output matches `TreeMaterializer`'s in every entry's type, mode, flags, mtime, birth time and
   size.
6. **AppleArchive's zero-block scan does not explain `extractStream`'s extra time on the 1 GiB incompressible
   file.** `extractStream` by default makes a hole of every aligned zero block (`AA_FLAG_EXTRACT_NO_AUTO_SPARSE`,
   `AAFlagSet.h`). Turning that off, and running the extract with one thread as well, changes nothing beyond
   run-to-run noise:

   | Writer | Wall (s) | User CPU (s) | System CPU (s) |
   |---|---|---|---|
   | extractStream | 0.420 | 0.690 | 0.190 |
   | extractStream, `.extractNoAutoSparse` | 0.438 | 0.705 | 0.187 |
   | extractStream, `.extractNoAutoSparse`, `threadCount: 1` | 0.427 | 0.687 | 0.177 |
   | TreeMaterializer | 0.271 | 0.276 | 0.083 |

   With `threadCount: 1`, each extract runs one `extractThreadProc` worker instead of ten; one file occupies one
   worker either way.
7. **`extractStream`'s remaining time on the 1 GiB file goes to its write path and to a thread polling the clock.**
   Of the samples not parked in a wait, with `.extractNoAutoSparse` set:

   | Where | Share |
   |---|---|
   | `pwrite`, from `flushBuf` under `afStreamWrite` on the extract worker | 35 % |
   | `retireThreadProc` looping on `gettimeofday`/`mach_absolute_time` and `pthread_mutex_lock`/`unlock` | 39 % |
   | `memmove`: the decoder's shared-buffer hand-offs 13 %, `decodeStreamReadData` 3 %, the extract worker's own buffer 3 %, the source and decompressor 3 % | 23 % |
   | condition-variable signalling | 2 % |

   No frame scans for zeros. `extractStream` spends 0.19 s of system time per GiB written against
   `TreeMaterializer`'s 0.08 s; the `pwrite` sizes are not visible without root. `TreeMaterializer`'s samples on the
   same file are 81 % `memmove` (the same source, decompressor, shared-buffer and decoder copies) and 15 % `write`.
8. **On a file that is 90 % zeros, `extractStream`'s holes make it the fastest writer, and `TreeMaterializer`
   allocates every zero.** The file is 512 repeats of 208 KiB of random bytes followed by 1,840 KiB of zeros:

   | Writer | Wall (s) | User CPU (s) | System CPU (s) | `st_blocks × 512` | `du -k` |
   |---|---|---|---|---|---|
   | extractStream | 0.167 | 0.856 | 0.090 | 109,051,904 | 106,496 |
   | extractStream, `.extractNoAutoSparse` | 0.448 | 1.043 | 0.182 | 1,073,741,824 | 1,048,576 |
   | TreeMaterializer | 0.252 | 0.525 | 0.071 | 1,073,741,824 | 1,048,576 |

   `extractStream`'s allocation is exactly the random data, 512 × 208 KiB, so every zero run became a hole.
   `TreeMaterializer` takes 1.5× its wall time and allocates 10× the space. 0 of the file's 65,536 pages were
   resident after any run.

   For findings 6 and 8, the slowest of a writer's five runs was at most 24 % above its median, except one
   `TreeMaterializer` run on the zero file at 0.376 s (+49 %).

## Method

A temporary SwiftPM package outside the repository held an executable target that depended by path on a copy of
`KernovaKit` at `a877d5b6`. It was built with `swift build -c release` (`-O`, whole-module), Swift 6.4
(swiftlang-6.4.0.34.1), so both writers ran from the same optimized binary. A second copy of `KernovaKit` was
patched so that `TreeMaterializer.apply` passed every settable attribute to one `fsetattrlist`/`setattrlistat`
call, with a buffer in the order CRTIME, MODTIME, ACCESSMASK, FLAGS and `fchown` still first. It was built the same
way for the "one call" rows.

- **TreeMaterializer** was driven through `ClipboardArchive.extract(_:into:)`.
- **extractStream** was the receiver's pipeline at `4c0526c9`, reproduced in the harness. An
  `ArchiveByteStream.customStream` over the in-memory archive fed `decompressionStream`, then a counting stream
  reporting every 1 MiB, then `decodeStream`. That went into `extractStream(extractingTo:selectUsing:flags:
  .ignoreOperationNotPermitted)` through `ArchiveStream.process`. The filter returned `.skip` at `extractBegin` for
  every type but file, directory and symlink, and cleared `UF_IMMUTABLE|SF_IMMUTABLE|UF_APPEND|SF_APPEND` at
  `extractAttributes`. The streams were closed in the order extract, decode, counter, decompress, read. The
  "no decmpfs" variant also cleared `UF_COMPRESSED` at `extractAttributes`.

The four sources were:

- a folder holding one 1 GiB file from `dd if=/dev/urandom bs=4m count=256`;
- the SDK's `System/Library/Frameworks` (2,278 directories, 9,641 files, 1,372 symlinks; 90 MB on disk);
- the toolchain's `usr/lib` (2,125 directories, 5,325 files, 29 symlinks; 767 MB on disk);
- a tree of 50 × 10 nested folders holding 100 files each, sized uniformly between 1,024 and 4,096 bytes and
  filled from `os.urandom`.

File-data totals are the sum of `st_size`. Each archive was built once with `ClipboardArchive.archiveBytes(of:
.directory(_:))` and saved to a file. The archives were 1,073,758,394, 68,478,667, 1,047,564,844 and 132,886,044
bytes.

Each run was a fresh process. It read the whole archive with `read(2)` into a `Data` and touched every 4 KiB of it
before timing, so the decoder read from RAM. It then created a fresh 0755 destination directory under
`/private/tmp`, on the internal APFS Data volume, and timed the extract. Wall time came from `CLOCK_MONOTONIC_RAW`
and CPU from `getrusage(RUSAGE_SELF)` deltas, which include AppleArchive's worker threads. After the extract,
`sync()` was timed on its own. The destination was removed with `rm -rf` after each run, and `sync; sleep 2` ran
before the next. The page cache was not purged, since that needs root. Each case ran five rounds, with the four
writers in a rotated order each round. Page residency of the landed 1 GiB file was read with `mincore(2)` over a
read-only `MAP_SHARED` `mmap` of the whole file.

Outputs were compared in one extra run per writer:

- `shasum` of every file in path order;
- `find … | xargs stat -f '%N %HT %Lp %f %m %B %z'` listings;
- `du -sk` for the on-disk size;
- `find -flags +compressed` to count the files `extractStream` compressed.

Profiles came from `sample <pid> 4 1` attached 0.4 s into a run on the 50,000-file tree; the shares are top-of-stack
counts on the thread running the extract. The worker count is the number of threads whose stacks hold
`extractThreadProc` in a `sample` of `extractStream` on the same tree, against `hw.ncpu` of 10.

Findings 6–8 came from a later session with the same harness, rebuilt from the same sources. Two variants were
added: `.extractNoAutoSparse` joined `.ignoreOperationNotPermitted` in `extractStream`'s flags, and
`threadCount: 1` was passed to both `extractStream` and `ArchiveStream.process`. The decompression and decode
streams kept their default thread counts in every variant, as both writers use them.

The 90 % zero file was written by Python: 512 repeats of 208 KiB from `os.urandom` followed by 1,840 KiB of
written zeros. That made 89.8 % zeros, in runs aligned to 16 KiB, and the source was fully allocated
(1,048,576 KiB). Its archive was 115,076,268 bytes. The 1 GiB incompressible file was made again with `dd`. Each
case ran five rotated rounds, timed as above. Each run's landed file was read with `stat` (`st_blocks × 512`) and
`du -k`.

For the 1 GiB profiles, one process ran ten extracts in a row, and `sample <pid> 2 1` was attached 0.8 s in. The
shares are self samples summed over every thread, leaving out `__psynch_cvwait`, `__semwait_signal`,
`__psynch_mutexwait` and `__ulock_wait`, and each is attributed to its two calling frames. The per-extract worker
count is the number of threads holding `extractThreadProc` in a one-second `sample` of the same process shape.
