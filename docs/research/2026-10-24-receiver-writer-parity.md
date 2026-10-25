# Receiver writer parity: `TreeMaterializer` with holes, one attribute call and folder batches, against `extractStream`

**Date:** 2026-10-24 · **Hardware:** M1 Max (MacBookPro18,4, 10 cores), 32 GB, internal SSD (APFS), macOS 27.2 (26B118), Xcode 27.1 (27A9275), on AC power

## Summary

The five sender archives of [the throughput note](2026-10-24-receiver-writer-throughput.md), each decoded from memory
by four writers: `extractStream` as the receiver configured it (**extractStream**), the same with `UF_COMPRESSED` also
cleared in its filter (**extractStream, no decmpfs**), `TreeMaterializer` at `9c237381` (**TreeMaterializer
before**), and `TreeMaterializer` at `e60f8367` (**TreeMaterializer after**). The after writer makes holes of zero
blocks, applies an entry's times, flags and mode in one `setattrlist` call, and creates a folder's symlinks and
regular files of up to 256 KiB side by side in batches of at most 256 entries and 8 MiB. Median of five runs; wall
time covers the extract alone.

| Case | Writer | Wall (s) | User CPU (s) | System CPU (s) | On disk |
|---|---|---|---|---|---|
| 1 GiB incompressible file (2 entries, 1.07 GB) | extractStream | 0.405 | 0.646 | 0.139 | 1 GiB |
| | extractStream, no decmpfs | 0.398 | 0.646 | 0.138 | 1 GiB |
| | TreeMaterializer before | 0.277 | 0.307 | 0.054 | 1 GiB |
| | TreeMaterializer after | 0.279 | 0.311 | 0.054 | 1 GiB |
| SDK `System/Library/Frameworks` (13,291 entries, 278 MB of file data) | extractStream | 1.960 | 4.411 | 4.463 | 98 MiB |
| | extractStream, no decmpfs | 0.839 | 0.863 | 4.306 | 288 MiB |
| | TreeMaterializer before | 1.801 | 0.192 | 1.684 | 288 MiB |
| | TreeMaterializer after | 1.052 | 0.223 | 3.133 | 288 MiB |
| Toolchain `usr/lib` (7,479 entries, 2.23 GB of file data) | extractStream | 20.333 | 44.540 | 3.327 | 843 MiB |
| | extractStream, no decmpfs | 1.266 | 2.248 | 2.762 | 2.07 GiB |
| | TreeMaterializer before | 1.488 | 0.988 | 1.179 | 2.09 GiB |
| | TreeMaterializer after | 1.347 | 1.026 | 1.533 | 2.07 GiB |
| 50,000 files of 1–4 KiB in 551 folders (128 MB) | extractStream | 1.956 | 1.967 | 12.052 | 195 MiB |
| | extractStream, no decmpfs | 1.987 | 2.059 | 12.046 | 195 MiB |
| | TreeMaterializer before | 6.068 | 0.346 | 5.720 | 195 MiB |
| | TreeMaterializer after | 2.027 | 0.372 | 11.903 | 195 MiB |
| 1 GiB file, 90 % zeros (2 entries) | extractStream | 0.173 | 0.846 | 0.085 | 104 MiB |
| | extractStream, no decmpfs | 0.176 | 0.847 | 0.085 | 104 MiB |
| | TreeMaterializer before | 0.239 | 0.523 | 0.064 | 1 GiB |
| | TreeMaterializer after | 0.113 | 0.526 | 0.069 | 104 MiB |

Every run fell within 10 % of its median except eight: `TreeMaterializer` before's first run on the 1 GiB file
(0.578 s, +109 %), the first run of `extractStream` with decmpfs off on it (+51 %), and the after writer's fourth
(+37 %); on the zero file, two runs of the before writer (+51 %, +29 %), two of the after writer (+28 %, +16 %) and
one of `extractStream` with decmpfs off (+11 %). A `sync()` issued after each extract took 0.06–0.09 s at the median
for every writer and case. "On disk" is `du -sk` of one run's output, and for the two single-file cases of every run,
which agreed.

1. **On the small-file tree the after writer matches `extractStream` with decmpfs off.** It takes 2.03 s, 40.5 µs
   of wall time per file, against 39.7 µs (1.02×); the before writer took 121 µs. Its system time is 11.9 s against
   `extractStream`'s 12.0 s: the creates now run side by side as `extractStream`'s do, and cost about as much CPU.
2. **On `System/Library/Frameworks` it is 1.25× `extractStream` with decmpfs off, down from 2.1×.** A batch holds
   one folder's entries, and this tree's 10,862 symlinks and files of up to 256 KiB sit in 2,101 folders, 5.2 to a
   folder on average; 193 folders hold ten or more. Its 2,278 directories, and the 151 files over 256 KiB, are
   created one at a time.
3. **On `usr/lib` it is 1.06× `extractStream` with decmpfs off, down from 1.18×, and holes take 20 MiB off its
   output.** The before writer's output was 2,192,196 KiB; the after writer's is 2,171,236 KiB, against
   `extractStream`'s 2,171,224 KiB with decmpfs off.
4. **On the 1 GiB incompressible file the zero scan costs nothing measurable.** Wall and system time are unchanged
   and user time is 4 ms higher, inside run-to-run spread. Alone, the scan of one 1 GiB buffer of random bytes in
   4 KiB blocks takes 1.6 ms, since each block's first 64 bytes are non-zero.
5. **On the 90 %-zeros file the after writer is the fastest, and allocates what `extractStream` allocates.** It takes
   0.113 s against `extractStream`'s 0.173 s and its own 0.239 s before; `st_blocks × 512` is 109,051,904 for both,
   exactly the file's 512 × 208 KiB of random data.
6. **On APFS, skipping zeros with a seek or a positional write leaves no hole; `F_PUNCHHOLE` does.** A file written
   as 4 KiB of data, a gap, and 4 KiB of data at its end allocates the gap in full up to a gap of 16 MiB, and leaves
   it a hole from a gap of 128 MiB:

   | Gap | `st_blocks × 512` | Size |
   |---|---|---|
   | 4 KiB | 12,288 | 12,288 |
   | 64 KiB | 73,728 | 73,728 |
   | 1 MiB | 1,056,768 | 1,056,768 |
   | 16 MiB | 16,785,408 | 16,785,408 |
   | 128 MiB | 24,576 | 134,225,920 |
   | 1 GiB | 24,576 | 1,073,750,016 |

   Writing 64 runs of 208 KiB at a 2 MiB stride allocated 128 MiB of 128 MiB with `pwrite`, with `lseek` and
   `write`, after an `ftruncate` to the full size, and with an `fsync` after each write; with `F_NOCACHE` on, 126.2
   MiB. Writing the zeros and punching them out allocated exactly the 13 MiB of data. A punch frees the range only
   once it lies inside the file: punched before the write past it, a 1 MiB gap stays allocated; punched after,
   or after an `ftruncate` that extends the file over it, it is freed.
7. **AppleArchive's auto-sparse is one `fpathconf(_PC_MIN_HOLE_SIZE)` and one `F_PUNCHHOLE` per zero run.**
   Interposing its calls during one `extractStream` of the zero file counted one `fpathconf` with
   `_PC_MIN_HOLE_SIZE` (4,096 on APFS), 512 `fcntl(F_PUNCHHOLE)`, 513 `pwrite`, one `fcntl(F_NOCACHE)`, two
   `fcntl(F_GETPATH)`, and no `ftruncate` or `lseek`. The after writer makes holes the same way: it skips each run of
   whole hole-sized blocks of zeros, and punches it once the next write, or the closing `ftruncate`, puts it inside
   the file.
8. **exFAT, FAT32 and HFS+ report no hole size, and every one reads a skipped gap back as zeros.** On 2 GB disk
   images of each, `fpathconf(_PC_MIN_HOLE_SIZE)` returned -1, so the after writer writes every zero there; the
   zero file landed byte-identical on all three, allocating its full 1 GiB. Written there as 208 KiB runs at a
   2 MiB stride ending with an `ftruncate`, a 32 MiB file read back with no byte other than zero in its gaps. A tree
   of 44 entries with modes, times, `UF_HIDDEN` and `UF_NODUMP` landed on each image with the same type, mode,
   flags, mtime, birth time and size per entry from the before and after writers.
9. **The zero scan needs word loads: a `SIMD64<UInt8>` comparison is 54× slower.** Scanning 1 GiB of zeros in
   4 KiB blocks:

   | Loop over each 64 bytes | ms per GiB |
   |---|---|
   | one `SIMD64<UInt8>` load compared `!= .zero` | 912 |
   | eight `UInt64` loads OR-ed | 17 |
   | four `SIMD2<UInt64>` loads OR-ed | 17 |
   | `memcmp` of each block against a zero block | 31 |

   An early build with the `SIMD64<UInt8>` comparison took 1.07 s on the zero file, 0.8 s of it user time.
10. **Batch limits move wall time little once a batch takes 64 entries.** Median of three runs per configuration:

    | Largest file | Byte budget | Entry budget | Small-file tree (s) | `Frameworks` (s) | `usr/lib` (s) |
    |---|---|---|---|---|---|
    | 256 KiB | 8 MiB | 16 | 2.414 | 1.135 | 1.456 |
    | 256 KiB | 8 MiB | 64 | 2.141 | 1.112 | 1.482 |
    | 256 KiB | 8 MiB | 256 | 2.099 | 1.127 | 1.459 |
    | 256 KiB | 8 MiB | 1,024 | 2.105 | 1.100 | 1.462 |
    | 256 KiB | 2 MiB | 256 | 2.100 | 1.113 | 1.475 |
    | 256 KiB | 32 MiB | 256 | 2.129 | 1.097 | 1.471 |
    | 64 KiB | 8 MiB | 256 | 2.148 | 1.140 | 1.541 |
    | 1 MiB | 8 MiB | 256 | 2.155 | 1.075 | 1.437 |
    | 1 MiB | 32 MiB | 1,024 | 2.140 | 1.090 | 1.450 |
    | 4 MiB | 16 MiB | 256 | 2.126 | 1.079 | 1.382 |

    The harness's maximum resident size, which includes the whole archive held in memory, was 11 MiB higher with a
    1 MiB largest file and 60 MiB higher with 4 MiB than with 256 KiB, on `usr/lib`.
11. **The after writer's output matches `extractStream`'s with decmpfs off.** On `System/Library/Frameworks`,
    `usr/lib` and the small-file tree, every entry has the same type, mode, flags, mtime, birth time and size, and
    every file the same SHA-1.

## Method

The harness of [the throughput note](2026-10-24-receiver-writer-throughput.md) was rebuilt the same way, with
`swift build -c release`, Swift 6.4 (swiftlang-6.4.0.34.1): one binary depended by path on a copy of `KernovaKit` at
`9c237381`, which also ran both `extractStream` writers, and a second on a copy at `e60f8367`. Each run was a fresh
process that read the whole archive into memory and touched every 4 KiB before timing, as there; destinations were
fresh 0755 directories under `/private/tmp` on the internal APFS Data volume, removed after each run, with
`sync; sleep 2` before the next. Each case ran five rounds, the four writers in a rotated order each round.

The `System/Library/Frameworks`, `usr/lib` and 1 GiB incompressible archives were the same size to the byte as
before: 68,478,667, 1,047,564,844 and 1,073,758,394 bytes. The small-file tree and the zero file were generated
again by the same recipe, so their archives were 132,440,381 and 115,076,267 bytes. The small-file tree is 50
folders each holding 10 folders of 100 files, sized uniformly from 1,024 to 4,096 bytes from `os.urandom`.

The batch-limit sweep used a third copy of `KernovaKit` at `e60f8367` whose three limits were read from environment
variables, three rounds per configuration in a fixed order, with `/usr/bin/time -l` for the resident size.

The hole probes (finding 6) were C programs writing to files under `/private/tmp`, reading `st_blocks` after closing
them. The interposition (finding 7) was a dylib with a `__DATA,__interpose` section replacing `fcntl`, `lseek`,
`pwrite`, `ftruncate` and `fpathconf`, loaded with `DYLD_INSERT_LIBRARIES` into the harness, which counted the calls
and printed them at exit. The disk images (finding 8) were made with `hdiutil create -size 2g -fs` `ExFAT`, `MS-DOS`
and `HFS+`, and attached with `-nobrowse`. The scan loops (findings 4 and 9) were timed by a separate `swiftc -O`
program, best of five passes over a 1 GiB buffer in 4 KiB blocks.

Outputs were compared (finding 11) in one extra run per writer with `find … | xargs stat -f '%N %HT %Lp %f %m %B %z'`
and `shasum` of every file, both in byte order of path. The per-folder counts in finding 2 are `find` over the SDK's
tree, counting symlinks and files of at most 256 KiB.
