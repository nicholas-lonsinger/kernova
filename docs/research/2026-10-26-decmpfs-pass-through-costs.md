# Decmpfs pass-through costs: end to end against the AppleArchive path, the checks that stay, and an LZ4 layer

**Date:** 2026-10-26 · **Hardware:** M1 Max (MacBookPro18,4, 10 cores), 32 GB, internal SSD (APFS), macOS 27.2 (26B123), Xcode 27.1 (27A9275) · **Power:** per finding; findings 1, 3, 4, 5 and 6 ran on AC with Low Power Mode off

## Summary

1. **Pass-through moves both trees with less work at each end than the AppleArchive path, and lands them at the
   source's own on-disk size.** Median of five runs. Each sender run read a fresh clone of the tree, so no
   data-fork page was cached. Receivers decoded from memory.

   | Tree | Path | Sender wall (user / sys) | Wire bytes | Receiver wall (user / sys) | On disk |
   |---|---|---|---|---|---|
   | Toolchain `usr/lib` (7,479 entries; 4,574 of 5,325 files compressed, all type 4; 2.23 GB logical; 785,708 KiB on disk) | AppleArchive today | 6.32 s (3.18 / 5.40) | 1,047,716,149 | 20.30 s (44.55 / 3.15) | 863,664 KiB |
   | | Pass-through | 1.27 s (0.01 / 0.67) | 794,467,471 | 0.99 s (0.01 / 0.98) | 785,688 KiB |
   | SDK `System/Library/Frameworks` (13,291 entries; 1,814 of 9,641 files compressed, all type 4; 278 MB logical; 92,424 KiB on disk) | AppleArchive today | 1.65 s (0.37 / 0.85) | 68,493,310 | 1.92 s (4.42 / 4.42) | 100,860 KiB |
   | | Pass-through | 1.12 s (0.01 / 0.57) | 73,087,698 | 1.23 s (0.01 / 1.21) | 92,408 KiB |

   - *AppleArchive today:* `ClipboardArchive.archiveBytes(of:)` (`read(2)`, encode, LZ4) and
     `ClipboardArchive.extract(_:into:)`. Its receiver compresses every flagged file again as LZVN: on `Frameworks`,
     68 files as type 7 and 1,746 as type 8. Its wire bytes are from one run; runs differ by under 4 KB.
   - *Pass-through:* compressed files travel as their `com.apple.decmpfs` and `com.apple.ResourceFork` bytes, every
     other file as plain bytes, with no compression layer. Its receiver is a single thread.
   - *The sender's cost is the kernel's decompression.* A plain `read(2)` of every file of `usr/lib` takes 5.85 s,
     5.22 s of it system time, against 1.27 s to read the attributes. A second read of the same clone takes
     0.47 s. On `Frameworks` the plain read takes 1.34 s.
   - *The receiver's cost is per entry, not per compressed file.* The same receiver writing the plain bytes of every
     file takes 0.93 s on `usr/lib` (2,192,196 KiB on disk) and 1.14 s on `Frameworks` (294,400 KiB).
     `extractStream` with `UF_COMPRESSED` cleared takes 1.27 s and 0.86 s.
   - *Wire:* pass-through's bytes on `usr/lib` are zlib resource forks, which an LZ4 layer leaves at 0.996 of their
     size. On `Frameworks`, LZ4 over 1 MiB blocks takes the pass-through stream to 0.686 of its size, about 50 MB,
     because its 7,827 plain files compress.
   - *Fidelity:* every entry of both trees landed with the source's type, mode, flags (`UF_COMPRESSED` included),
     size, mtime, birth time, link target and SHA-256, for both paths.
2. **AppleArchive's receiver is bound by one LZVN compression per file, and the decoder waits on it.** In a `sample`
   of the `usr/lib` extract, the thread running `ArchiveStream.process` spends 95 % of its samples in
   `extractStreamWriteBlob` → `SharedBufferWrite`, waiting for the worker handling the current file. That worker
   compresses it in `afscStreamWrite` → `compression_encode_buffer` (LZVN). Across the ten `extractThreadProc`
   workers, LZVN encoding holds 1.3 threads' worth of samples.
   - *Speed:* single-core LZVN encode of `libclang.dylib` in 64 KiB chunks runs at 69 MB/s. LZBITMAP runs at
     234 MB/s, LZFSE at 104 MB/s and LZ4 at 687 MB/s.
   - *What changes nothing:* on AC, `extractStream` with `threadCount` 64 takes 20.23 s against the default's
     20.30 s. Under Low Power Mode, 4 and 20 threads take 27.0 and 26.0 s against the default's 26.1 s. One thread
     takes 35.2 s. No `AAFlagSet.h` flag selects the algorithm.
   - *Parallel streams:* eight extract streams, each fed by its own thread from a 256 MiB in-memory budget, land
     `usr/lib` in 6.27 s with the same 863,664 KiB. With a 64 MiB budget they take 8.63 s.
3. **Every flag write after `UF_COMPRESSED` is set must carry `UF_COMPRESSED`, or the file is emptied without an
   error.** Each row is a file recreated from the attributes (resource fork, then `com.apple.decmpfs`, then
   `fchflags(UF_COMPRESSED)`), changed by one call, then read in full. The results are the same for `/bin/ls`
   (type 8), `libclang.dylib` (type 4, 127 MB) and `/usr/bin/pp` (type 9):

   | Call after the flag | Result |
   |---|---|
   | `fchflags`, `chflags`, `lchflags` with flags lacking `UF_COMPRESSED` (`0`, `UF_HIDDEN`, `UF_NODUMP`) | Emptied: flag cleared, `st_size` 0, read returns 0 bytes |
   | `fsetattrlist` `ATTR_CMN_FLAGS` alone, or `setattrlist` CRTIME + MODTIME + ACCESSMASK + FLAGS, lacking `UF_COMPRESSED` | Emptied |
   | Any of the above with `UF_COMPRESSED` in the flags | Intact |
   | `fremovexattr(com.apple.decmpfs)` | Emptied |
   | `ftruncate(0)` on the creation descriptor | Emptied |
   | `fsetxattr(com.apple.decmpfs)` again, same bytes | Decompressed in place: flag cleared, contents intact, `st_blocks` grows (112 → 496 for `/bin/ls`) |
   | `open(O_RDWR)` or `open(O_WRONLY)` | Decompressed in place |
   | `write` on the creation descriptor | `EACCES`; intact |
   | Times (`fsetattrlist` CRTIME + MODTIME, `utimes`), `fchmod`, `fchown` to the receiver and gid 20 | Intact |
   | `fsetxattr` / `fremovexattr` of `user.test`, `fsetxattr` of `com.apple.quarantine` | Intact |
   | `open(O_RDONLY)`, `rename` within the folder, `copyfile(COPYFILE_ALL)` to a new file | Intact, and the copy is compressed |

   An emptied file keeps its resource fork's blocks: `libclang.dylib` emptied shows `st_size` 0 and 84,632 blocks.
4. **At creation, the attributes go before the flag, and the descriptor's access mode does not matter.**
   - *Flag first:* setting `UF_COMPRESSED` before the attributes leaves a 0-byte file without the flag, and the
     attributes then written keep their blocks.
   - *Order:* `com.apple.decmpfs` before the resource fork works as well as the reverse.
   - *Access mode:* a descriptor opened `O_WRONLY`, `O_RDWR` or `O_RDONLY` with `O_CREAT | O_EXCL` takes both
     `fsetxattr` calls and the `fchflags`, and the file reads back identical.
   - *What the probe receiver did:* it set the full flag word, `UF_COMPRESSED` included, in one `fchflags` after the
     attributes, then `fchmod` and the times. Times go after the flag because setting it resets mtime
     (docs/research/2026-10-24-decmpfs-pass-through.md, finding 3).
5. **`VOL_CAP_FMT_DECMPFS_COMPRESSION` costs about 1 µs per check, and without it an exFAT destination gets
   0-byte files.**
   - *Cost:* `fgetattrlist` with `ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES` on a directory descriptor takes 0.93 µs
     per call over 100,000 calls on APFS and 0.99 µs on exFAT. `getattrlist` by path takes 1.05 µs and 1.03 µs. A
     process's first call takes 4.5–22.6 µs.
   - *What it reports:* the bit is valid and supported on APFS, and valid and unsupported on exFAT.
   - *exFAT without the check:* recreating `libLTO.dylib` (type 4, 69 MB), `/bin/ls` and `/usr/bin/pp` on an
     `hdiutil` exFAT image gives this:
     - both `fsetxattr` calls return 0;
     - `fchflags(UF_COMPRESSED)` returns `EINVAL`;
     - each file is 0 bytes and lists the two attribute names;
     - the attributes are stored in AppleDouble `._` files: 23,541,045 bytes for `libLTO.dylib`, 58,348 for `ls`
       and 4,096 for `pp`.
6. **This host's kernel reads types 3, 4, 7–9 and 11–16. Type 10 read back nothing in every layout tried.**
   - *Built from plain text:* the files read back byte-identical. Types 3 (zlib), 7 (LZVN), 9 (raw), 11 (LZFSE),
     13 (LZBITMAP) and 15 (LZ4) were stored in the attribute, at 3,000 bytes (100 for type 9). Types 8, 12, 14 and
     16 were stored in the resource fork as 64 KiB chunks behind an offset table, at 10,000,000 bytes.
   - *Type 4:* recreated from `libLTO.dylib`'s and `libclang.dylib`'s own attributes, the files read back identical.
   - *Type 10:* raw 64 KiB chunks with no prefix, with a `0xff` prefix, and with a `0x06` prefix each give a file
     whose flag sticks and whose read returns 0 of 10,000,000 bytes, with no error. No file surveyed here or in the
     2026-10-24 note uses type 10.
   - *What the trees use:* both test trees are entirely type 4. `/System/Library/Frameworks` on this host is type 8
     (12,976 files) and type 9 (137) in the first 537 MB of attributes walked.
7. **Kernova's range spans kernels 26–27 on the host and 12.0–27 in the guest, and this host settles only macOS 27.2
   (26B123).** `MACOSX_DEPLOYMENT_TARGET` is 26.0 and `KERNOVA_AGENT_DEPLOYMENT_TARGET` is 12.0. Settling the matrix
   takes a macOS VM of each of these: 12.0, the last 12.x, 13, 14, 15 and 26, plus 27 on any build other than
   26B123. A macOS 26 VM also stands in for a macOS 26 host kernel. In each, four things need settling:
   - which of types 3, 4 and 7–16 its kernel reads back (finding 6's probe), which decides what host → guest may
     send;
   - which types its own content uses, which decides what guest → host carries;
   - whether finding 4's creation order and finding 3's table hold;
   - what `VOL_CAP_FMT_DECMPFS_COMPRESSION` reports on its startup volume.
8. **`COMPRESSION_LZ4_RAW` encodes at 0.4–1.0 GiB/s and decodes at 1.6–23 GiB/s on one core. On ten cores
   encoding reaches 3.4–8.7 GiB/s.** These runs were on battery with Low Power Mode on. Best of nine runs, with the
   median within 11 % of it in every cell; ratio is output over input, with a block that does not shrink counted
   at its raw size:

   | Payload | Ratio, 64 KiB / 256 KiB / 1 MiB blocks | Encode, 1 core / 10 | Decode, 1 core / 10 |
   |---|---|---|---|
   | Source: 10,733 `.swift`, `.h`, `.c`, `.m`, `.md` files (118 MB) | 0.288 / 0.273 / 0.270 | 0.67 / 6.10 GiB/s | 2.93 / 26.0 GiB/s |
   | `usr/lib` binaries, plain bytes (538 MB) | 0.469 / 0.459 / 0.457 | 0.63 / 5.68 GiB/s | 2.96 / 26.9 GiB/s |
   | Text: `/usr/share/dict` and this repo's Markdown (135 MB) | 0.564 / 0.559 / 0.558 | 0.37 / 3.46 GiB/s | 1.60 / 14.5 GiB/s |
   | Media: wallpaper `.heic` and `.mov` (540 MB) | 0.998 / 0.998 / 0.998 | 1.02 / 8.69 GiB/s | 23.4 / 76.4 GiB/s |
   | Pass-through bytes, type 4 (`usr/lib` attributes, 537 MB) | 0.998 / 0.998 / 0.998 | 1.00 / 8.59 GiB/s | 17.3 / 67.2 GiB/s |
   | Pass-through bytes, types 8 and 9 (`/System/Library/Frameworks` attributes, 537 MB) | 0.933 / 0.929 / 0.927 | 0.91 / 7.81 GiB/s | 9.34 / 57.7 GiB/s |

   Block size changes the ratio by at most 0.018, and throughput by no more than run-to-run noise. Encode and decode
   figures are the best block size's. At 64 KiB, 94 % of media blocks and 75 % of type-4 blocks do not shrink.
9. **An LZ4 layer raises throughput only guest → host, only on compressible payloads, and only with at least two
   encoding cores. Host → guest it lowers throughput even on ten cores.** Throughput with the layer is
   min(encode, decode, link ÷ ratio); without it, it is the link. The links are ~750 MiB/s guest → host and
   ~6,400 MiB/s host → guest once `SO_SNDBUF` is raised (docs/research/2026-07-13-vsock-transport-throughput.md),
   which `VsockListener` does. The *n*-core rows below multiply finding 8's single-core rate. They are arithmetic,
   not measurements, and assume a guest vCPU encodes at a host core's rate:

   | Payload | Guest → host, 1 core | 2 cores | 4 cores | Host → guest, 10 cores |
   |---|---|---|---|---|
   | Source | 0.92× | 1.8× | 3.7× | 0.98× |
   | `usr/lib` binaries | 0.86× | 1.7× | 2.2× (link-bound) | 0.91× |
   | Text | 0.51× | 1.0× | 1.8× (link-bound) | 0.55× |
   | Media | ≤1.002×, ~1 core-second per GiB | — | — | ≤1.002× |
   | Pass-through, type 4 | ≤1.002× | — | — | ≤1.002× |
   | Pass-through, types 8/9 | 1.08× (link-bound) | 1.08× | 1.08× | 1.08× (link-bound) |

   Host → guest, ten cores encode source at 6.10 GiB/s and binaries at 5.68, both under the 6.25 GiB/s link, so
   the layer costs time there.
10. **`COMPRESSION_LZ4_RAW` is the standard LZ4 block format, and `COMPRESSION_LZ4` is not the LZ4 frame format.**
    - *Interoperability:* every block of every payload above, plus the pass-through containers, decoded through
      liblz4 1.10.0's `LZ4_decompress_safe` to the original bytes, at 64 KiB and at 1 MiB. Every block
      `LZ4_compress_default` produced decoded through `compression_decode_buffer(COMPRESSION_LZ4_RAW)`. That is
      36,695 blocks of 64 KiB and 3,393 of 1 MiB each way.
    - *Ratios:* liblz4's ratios are within 0.01 of Apple's.
    - *Apple's framing:* `compression.h` documents `COMPRESSION_LZ4` as Apple's own frame of `bv41`, `bv4-` and
      `bv4$` block headers around the raw stream, and `LZ4_RAW` as "compatible with the LZ4 library, without the
      frame headers". It also notes that "a compressed block may reference data from the previous block". Each
      `compression_encode_buffer` call's output decoded on its own, with no preceding block.

## Method

**Probes.** All probes ran from a terminal: account uid 501, no `sudo`, no sandbox, on the internal APFS Data volume
under the session scratch directory.
- *Pass-through probe:* a standalone C program, built with `clang -O2` (`-lcompression -lz`).
- *AppleArchive harness:* a SwiftPM executable depending by path on this repository's `KernovaKit` at
  `c06088a5`, built with `swift build -c release` (Swift 6.4).
- *LZ4 benchmark:* a C program, built with `clang -O2`.
- *Interoperability check:* a C program linked against Homebrew's static `liblz4.a` 1.10.0.

**Trees.**
- The toolchain's `usr/lib` and the SDK's `System/Library/Frameworks` (Xcode 27.1).
- Before each sender run, the tree was cloned with `cp -Rc` and the clone was read. A clone's data fork reads cold:
  5.95 s for the plain read of `usr/lib`'s clone against 0.47 s on its second read. Each clone was then removed.
- `sync` and a 2 s pause preceded every timed run. The page cache was not purged.
- Rounds rotated the order of the variants.

**AppleArchive path.**
- *Sender:* the harness timed `ClipboardArchive.archiveBytes(of: .directory(_:))`.
- *Receiver:* the harness timed `ClipboardArchive.extract(_:into:)` over the archive held in memory.
- *Controls:* the harness reproduced the receiver's pipeline with `threadCount` set, or with `UF_COMPRESSED` added
  to the filter's cleared flags.
- *Parallel variant:* a router stream sent each `UF_COMPRESSED` file's header and copied blobs to one of eight
  threads, each driving its own `extractStream`. It created each directory itself with `mkdirat` and
  `openat(O_NOFOLLOW)`, sent other entries to a ninth stream, and fed the directory headers to a final
  `extractStream` after the others closed. Handed to the threads as `process` passed them, the headers'
  entries failed. Copied through `withAAEncodedData` first, every entry landed.
- *Profile:* `sample <pid> 6 1`, attached 6 s into a `usr/lib` extract. That run and the LZVN/LZBITMAP/LZFSE/LZ4
  timings ran on battery with Low Power Mode on: the extract then took 26.1 s. LZVN timed 69.3 MB/s on AC and
  67.7 MB/s on battery.

**Pass-through path.**
- *Sender:* `fts` walked the tree physically. For a regular file with `UF_COMPRESSED`, it read `com.apple.decmpfs`
  and `com.apple.ResourceFork` with `fgetxattr(…, XATTR_SHOWCOMPRESSION)`. It read any other file with `read(2)` in
  4 MiB blocks.
- *Container:* each entry was appended to a memory buffer: kind, path, mode, flags, mtime and birth time, then the
  attribute bytes, the plain bytes or the link target.
- *Wire bytes:* the buffer's size.
- *Receiver:* it loaded the container into memory and, on one thread, did the following for each entry:
  - *Directory:* created it with `mkdirat` mode 0700.
  - *Symlink:* created it with `symlinkat`, then `setattrlistat(FSOPT_NOFOLLOW)`.
  - *Compressed file:* `openat(O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW)`, `fsetxattr` of the resource fork and
    then `com.apple.decmpfs` with `XATTR_SHOWCOMPRESSION`, then one `fchflags` with every flag but the withheld set
    and with `UF_COMPRESSED`. No read-back.
  - *Plain file:* `write` in 4 MiB blocks, then `fchflags` when any flag was set.
  - *Every file:* then `fchmod` and `fsetattrlist` CRTIME + MODTIME.
  - *After the last entry:* directory flags, mode and times through one `setattrlistat` each, latest entry first.
  - *Withheld flags:* `UF_IMMUTABLE | UF_APPEND | UF_DATAVAULT | SF_SETTABLE`, as `ClipboardArchiveCodec`
    withholds them.
- *Verification:* a Python script compared each landed tree with the clone it was sent from, entry by entry. On
  disk is `du -sk`; compressed counts are `find -type f -flags +compressed`.

**Hazards and types.**
- *Recreation:* each row began from a fresh file recreated from the source's attributes with `O_RDWR | O_CREAT |
  O_EXCL`. The probe then made the one call, closed the file, and compared `lstat` and the SHA-256 of a full read
  with the source's.
- *Types:* type files were built from `/usr/share/dict/words` with `compression_encode_buffer`. LZVN used algorithm
  `0x900`, which `compression.h` does not declare; type 3 used zlib's `compress2`.
  - *Attribute types:* a 16-byte header (`fpmc`, type, size) was followed by the payload, with type 9's `0xcc`
    marker.
  - *Resource-fork types:* the fork held `n + 1` little-endian u32 offsets and then 64 KiB chunks.

**Volume check and exFAT.** The probe timed 100,000 calls of each form in one process, and one call in a fresh
process. The exFAT volume was a 256 MB `hdiutil create -fs ExFAT` image, attached with `-nobrowse -mountpoint`,
detached and deleted afterwards.

**LZ4.**
- *Payloads:* each payload concatenated the files of a sorted walk. Text repeats its 64 MB of files once; the
  repeat lies beyond LZ4's 64 KiB window. The pass-through payloads concatenate `com.apple.decmpfs` and resource
  fork bytes as stored.
- *Runs:* each cell encoded every block with `compression_encode_buffer(…, COMPRESSION_LZ4_RAW)` and then decoded
  it, nine times. The 10-thread cells used ten threads taking blocks from a shared counter, each with its own
  scratch buffer. A full round trip was compared with the input.
- *Conditions:* the machine ran on battery with Low Power Mode on and its lid closed, waking for maintenance
  windows. In an earlier sweep in the same state, single runs took up to 200× the fastest. The reported figures are
  therefore the best of nine runs, with the median checked against it.
- *Wire ratios:* the ratios over the pass-through containers came from the interoperability check at 1 MiB blocks.

**Sources read.**
- The SDK's `compression.h`, `AppleArchive/AAFlagSet.h`, `AppleArchive/AAArchiveStream.h`, `sys/attr.h` and
  `sys/xattr.h`.
- `Config/Base.xcconfig` for the deployment targets.
