# Carrying a transparently compressed file in its compressed form: reading, recreating and verifying decmpfs files

**Date:** 2026-10-24 · **Hardware:** M1 Max (MacBookPro18,4, 10 cores), 32 GB, internal SSD (APFS), macOS 27.2 (26B118), Xcode 27.1 (27A9275)

## Summary

1. **A compressed file is its `UF_COMPRESSED` flag, a `com.apple.decmpfs` attribute, and for most files a
   `com.apple.ResourceFork` attribute. The data fork holds nothing.**
   - *Hidden by default:* `flistxattr` with options 0 returns 0 bytes on every compressed file sampled. With
     `XATTR_SHOWCOMPRESSION` it returns the two names, resource fork first, plus any ordinary attributes the file has.
   - *Sizes:* `com.apple.decmpfs` is 16 bytes when a resource fork holds the data. Examples: `/bin/ls` has 16 + 54,538
     bytes for an `st_size` of 252,512; `/usr/bin/zip` has 16 + 273,815 for 617,856; `Helvetica.ttc` has
     16 + 1,064,069 for 2,338,064. A small file keeps its data in the attribute and has no resource fork:
     `/usr/bin/pp` has an 80-byte `com.apple.decmpfs` for 63 bytes.
   - *Header:* the attribute starts with a 16-byte little-endian header: magic `0x636d7066` (`fpmc` on disk),
     compression type (u32), uncompressed size (u64) (XNU `bsd/sys/decmpfs.h`, `decmpfs_disk_header`). `st_size` is the
     header's uncompressed size. `st_blocks` counts the resource fork's allocation: 112 blocks for `/bin/ls`, 0 for
     `/usr/bin/pp`. `read(2)` returns the logical bytes.
   - *Nothing else:* recreating the two attributes and the flag reproduced every sampled file byte for byte
     (findings 3 and 7). The file's other attributes are separate from compression.
2. **This Mac's content uses types 4, 8, 9 and 14. AppleArchive's extract writes types 7 and 8.** Counts of the type
   field over every readable `UF_COMPRESSED` regular file in each tree:

   | Tree | 4 (zlib, resource fork) | 8 (LZVN, resource fork) | 9 (raw, in the attribute) | 14 (LZBITMAP, resource fork) |
   |---|---|---|---|---|
   | `/System/Library` | — | 102,118 | 30,860 | 362 (all under `AssetsV2`) |
   | `/usr` | — | 15,565 | 787 | — |
   | `/Library` | — | 19,141 | 265 | — |
   | `/Applications` | 26,725 (26,609 in Xcode.app) | — | — | — |

   Type 9 holds files of up to 111 bytes. The largest resource fork found was 197,386,249 bytes, for a 442,630,880-byte
   file in `CoreRE.framework`. `aa extract` of an archive of `/usr/share/zoneinfo.default` wrote type 7 (LZVN, in the
   attribute) on 352 files and type 8 on 3. No surveyed file used types 3, 7, 10, 11, 12, 13, 15 or 16.
   The layouts were confirmed by decoding real files with `libcompression` and zlib and matching `read(2)`:
   - *In the attribute (types 7, 9):* the payload follows the 16-byte header. Type 9 is the marker byte `0xcc`
     followed by the raw bytes.
   - *Types 8 and 14:* the resource fork starts with a table of `n + 1` little-endian u32 offsets, followed by
     64 KiB chunks. A chunk stored raw starts with `0x06` (LZVN) or `0xff` (1,208 of the type-14 file's 1,218 chunks).
   - *Type 4:* the resource fork's block table is at offset `0x104`: a count, then (offset, length) pairs relative to
     `0x104`, each block a zlib stream.
3. **An unprivileged process recreates a compressed file with public calls: both attributes, then the flag.**
   - *Steps:* into a fresh empty file, `fsetxattr` the resource fork and then `com.apple.decmpfs`, then set
     `UF_COMPRESSED` with `fchflags` or with `fsetattrlist` `ATTR_CMN_FLAGS`. The flag sticks, `st_size` is the
     logical size, `st_blocks` equals the source's, and the file reads back identical (SHA-256).
   - *Options that work:* the attributes can go in either order, with or without `XATTR_SHOWCOMPRESSION` while the
     file is not yet compressed. The resource fork can be written in pieces through `fsetxattr`'s position argument:
     4 KiB pieces, 1 MiB pieces, and one call of about 530–760 MB (each 1 GiB file of finding 10) all worked.
   - *Flag first:* `fchflags` returns 0, the flag is not set, and the file stays empty.
   - *Data first:* writing the plain bytes before the attributes and flag works, and setting the flag truncates the
     data fork. This matches `decmpfs_update_attributes`, which accepts the flag only when the attribute exists and
     then sets `va_data_size = 0` ("you must first do the setxattr and then the chflags", XNU `bsd/kern/decmpfs.c`).
   - *Times:* setting the flag resets `st_mtimespec` to now and keeps the birth time. Times applied after the flag
     land.
   - *`copyfile` does the same:* `copyfile_xattr` copies the attributes in `flistxattr` order with
     `XATTR_SHOWCOMPRESSION`, and only for types 3, 4, 7–14. `copyfile_data` then sets `UF_COMPRESSED` instead of
     copying data, and if the flag does not stick it removes both attributes and copies the data plainly.
     `copyfile_stat` sets the final flags, which include `UF_COMPRESSED`, and re-applies the times "since
     `FSIOC_CAS_BSDFLAGS(UF_COMPRESSED)` resets file times". `copyfile` sets flags through
     `ffsctl(FSIOC_CAS_BSDFLAGS)` first and falls back to `fchflags`. That ioctl is declared only in XNU's
     `bsd/sys/fsctl.h`, and the SDK has no `sys/fsctl.h`. It also sets the flag here; `fchflags` alone suffices.
4. **Any later flag write that leaves out `UF_COMPRESSED` empties the recreated file without an error.**
   - *What happens:* after the flag is set, `fsetattrlist`/`setattrlist` with `ATTR_CMN_FLAGS = UF_HIDDEN` returns 0
     and clears the flag. That is true on the creation descriptor, by path, and in the combined
     CRTIME/MODTIME/ACCESSMASK/FLAGS call. The file is then 0 bytes, with `st_size` 0, and `read` returns 0. With
     `UF_HIDDEN | UF_COMPRESSED` the file stays intact.
   - *Steps that are safe:* times, mode and `fchown` leave the file compressed and intact.
   - *Opening for write:* `open(O_RDWR)` on a compressed file decompresses it in place, clearing the flag and growing
     `st_blocks` from 112 to 496 for `/bin/ls`. A flag write after that no longer loses data.
5. **Apple documents reading these attributes, and calls setting the flag undefined.**
   - *`man 2 chflags`:* "The `SF_DATALESS` and `UF_COMPRESSED` flags are internal flags and may not be set or unset
     from user space. Attempting to modify them using chflags() will result in undefined behaviour."
   - *`man 2 getxattr` and `man 2 listxattr`:* `XATTR_SHOWCOMPRESSION` exposes "HFS Plus Compression extended
     attribute(s)" to the get and list calls. `man 2 setxattr` does not mention it.
   - *Not in the SDK:* there is no decmpfs header, and the compression types are "defined in AppleFSCompression
     project" (XNU `decmpfs.h`). The layout in finding 2 comes from decoding files.
6. **Inside the App Sandbox, every step works with no entitlement beyond `com.apple.security.app-sandbox`.**
   - *Setup:* an ad-hoc-signed app bundle with only that entitlement, launched through `open`. Its `HOME` and `TMPDIR`
     were its container, and opening `~/Documents` returned `EPERM`.
   - *Reading:* it read `com.apple.decmpfs` and the resource fork of `/bin/ls`, `/usr/bin/zip` and `Helvetica.ttc`
     with `XATTR_SHOWCOMPRESSION`.
   - *Writing:* it recreated each one in its container with `fchflags`, with `fsetattrlist`, and with the
     `FSIOC_CAS_BSDFLAGS` ioctl, each byte-identical. It also built type-12 and type-14 files there from its own
     plain data.
   - *Quarantine:* every file it created also carried `com.apple.quarantine`.
7. **This kernel reads types 3, 4, 7–16, and every other type either fails `open` or reads back nothing.**
   - *Types that read back:* files built in each type from plain data read back byte-identical:
     - in the attribute (3,000 bytes): 3 (zlib), 7 (LZVN), 9 (raw), 11 (LZFSE), 13 (LZBITMAP), 15 (LZ4);
     - in 64 KiB chunks (10,000,000 bytes): 8, 10 (raw), 12, 14, 16 (LZ4).
     Type 4 comes from the Xcode files. Types 15 and 16 read back only when the payload is `COMPRESSION_LZ4`; every
     other `libcompression` algorithm, written under those types, read back 0 bytes. `copyfile` 240 does not list 15 or
     16, so `copyfile` itself copies them uncompressed.
   - *Types that fail `open`:* `open` fails with `EIO` for types 0, 2, 6, 17–20 and 254, and with `EINVAL` for type 1.
     `XNU` registers type 1 itself as raw data in the attribute.
   - *Types that read back nothing:* types 5, 255 and 256 open and read 0 bytes with no error. Type 5 keeps `st_size`
     at the logical size; 255 and 256 show `st_size` 0. Type `0x80000001` (dataless) returns `ETIMEDOUT` on read.
8. **The open-source record dates types 3–12 back to 10.11. LZBITMAP reached `libcompression` and `copyfile` with
   macOS 12, and types 15 and 16 appear in no source examined.**
   - *Types 3–12:* `copyfile.c`'s comment says types 7–10 "were added in 10.10, Types 11 & 12 were added in 10.11".
   - *Types 13 and 14:* `copyfile.c` at the macOS 11.5 release (`distribution-macOS` tag `macos-115`) has no
     LZBITMAP case. At macOS 12.0.1 (`macos-1201`) it lists 13 and 14. The SDK's `compression.h` marks
     `COMPRESSION_LZBITMAP` "available starting macOS 12.0".
   - *Where the decoders live:* XNU's history cannot settle which kernel reads which type. XNU keeps a registration
     table (`decompressors[CMP_MAX]`), and the decoders register from AppleFSCompression, which is closed. A type a
     kernel has not registered fails `open` (finding 7).
   - *Kernova's range:* Kernova's guest agent targets macOS 12.0 (`KERNOVA_AGENT_DEPLOYMENT_TARGET`). This Mac's own
     content uses type 14, and no macOS 12 kernel was tested here.
9. **Only a full read-back compared with a digest of the plain data catches every corruption. Cheaper checks catch
   some cases, and the rest return wrong bytes or too few with no error.** Each case was a recreated file with one
   field or byte changed. Results were the same for types 8, 12 and 14 unless the table says otherwise:

   | Change | Flag after `fchflags` | `open` | `read` |
   |---|---|---|---|
   | Header under 16 bytes, wrong magic, or an attribute over 3,802 bytes (`MAX_DECMPFS_XATTR_SIZE`) | not set (`fchflags` returns 0) | succeeds | 0 bytes, `st_size` 0 |
   | Uncompressed size changed (smaller, larger, 0) | set | `EINVAL` | — |
   | Resource fork truncated, or missing | set | `EINVAL`, or `ENOATTR` | — |
   | Offset table byte changed | set | succeeds | 0 bytes, no error |
   | One byte changed in a type-8 chunk | set | succeeds | 3,145,728 of 10,000,000 bytes, no error |
   | One byte changed in a type-12 or type-14 chunk | set | succeeds | all 10,000,000 bytes, content wrong, no error |
   | Type 4: a byte in the first block; a byte in the header's unused area | set | succeeds | 0 bytes; identical |
   | In the attribute (types 3, 7, 9, 11, 13): first payload byte changed, payload cut to 17 or 1,000 bytes, or header size 3,001 | set | succeeds | 0 bytes, except type 11 cut to 1,000: 3,000 wrong bytes |
   | In the attribute: byte 500 changed | set | succeeds | 3,000 bytes, content wrong |
   | In the attribute: header size 2,999 | set | succeeds | 2,999 bytes, `st_size` 2,999 |

   - *A flag check* catches only the first row.
   - *A successful `open`* catches the size and resource-fork rows, and unregistered types (finding 7).
   - *Comparing bytes read with an expected logical size* also catches the zero-length and short reads, types 5, 255
     and 256, and the 2,999-byte header, but only when the expected size comes from outside the attribute: `st_size`
     is the header's own value.
   - *Only a digest* catches the rows that read back full-length wrong content.
10. **A read-back of a newly recreated file costs 0.4–1.5 s of kernel CPU per GiB, depending on the type, plus
    0.45 s/GiB to hash it.** Per 1 GiB file, built from text and read with `dd bs=1m` on its first read after creation:

    | Type | First read | Second read |
    |---|---|---|
    | 8 (LZVN) | 1.43 s, all system time | 0.06 s |
    | 12 (LZFSE) | 1.45 s | 0.06 s |
    | 14 (LZBITMAP) | 0.43 s | 0.06 s |

    Reading with SHA-256 (CommonCrypto) took 2.30, 1.92 and 0.89 s, and 0.51 s for a plain file already in the page
    cache. A first read-back of the 14,013 type-8 files of `/System/Library/Frameworks` (1.49 GB logical), recreated in
    a fresh folder, took 1.74–2.21 s; a second took 0.57–0.66 s. The decompression ran as system time in the reading
    thread.
11. **Pass-through saves the sender's decompression and 60 % of the bytes, and costs the receiver more per file.**
    The test set was the same 14,013 files, 1,491,623,169 logical bytes and 587,045,341 bytes of attributes:
    - *Sender:* reading both attributes of every file took 0.99 s. Reading the data fork of every file took
      1.66–1.71 s. Both ran over copies recreated just before and never read, three runs each.
    - *Receiver, from memory:* recreating the files compressed took 1.72–1.82 s (125 µs per file). Writing them plain
      took 1.21–1.24 s (87 µs per file), five runs each. The output was 614,316 KiB against 1,494,320 KiB.
    - *One 1 GiB file:* the compressed write took 0.07–0.17 s and the plain write 0.17–0.34 s, three runs each per type.
12. **On exFAT, both attributes are stored as ordinary attributes, and the flag is refused with `EINVAL`.**
    - *Writing:* on an `hdiutil` exFAT image, `fsetxattr` of the resource fork and `com.apple.decmpfs` returned 0
      with or without `XATTR_SHOWCOMPRESSION`. A 58,348-byte `._ls` AppleDouble file appeared.
    - *The flag:* `fchflags` and `fsetattrlist` with `UF_COMPRESSED` returned −1 `EINVAL`.
    - *The result:* a 0-byte file with two visible attributes.
    - *A check beforehand:* `fgetattrlist` `ATTR_VOL_CAPABILITIES` reports `VOL_CAP_FMT_DECMPFS_COMPRESSION` valid and
      unsupported on the exFAT volume, and supported on APFS. This is the check `copyfile`'s `doesdecmpfs` makes on
      both ends.
13. **The archive carries both attributes either as an `XAT` blob or as custom blob keys with an empty `DAT`, and the
    receiver recreates the file from either. AppleArchive never reads them itself.**
    - *AppleArchive's own reads:* `ArchiveHeader.EntryXATBlob(directory:path:flags:)` returns an empty blob for
      compressed files. `aa archive -include-field xat` stored only `user.test` (`XAT[19]`) for a compressed file
      carrying that attribute, so AppleArchive reads attributes without `XATTR_SHOWCOMPRESSION`.
    - *The test archive:* entries were written through `encodeStream` over LZ4, each with `TYP`, `PAT` and `DAT` of
      size 0. One form carried an `EntryXATBlob` built from the two attributes. The other carried custom blobs `RFK`
      (resource fork) and then `DMP` (`com.apple.decmpfs`). The resource fork was written in 1 MiB `writeBlob`
      pieces.
    - *The result:* after decoding, the attributes were written in blob order and the flag set. Every entry read back
      identical in both forms. The sources were `/bin/ls`, `/usr/bin/pp`, built type-11, 12 and 14 files, and the
      442,630,880-byte `CoreRE` file.
    - *`XAT` against custom keys:* an `XAT` blob is one value, `[u32 size including itself][name NUL][value]` per
      attribute. The receiver therefore holds the whole resource fork in memory, 197 MB for the `CoreRE` file. `RFK`
      streams into `fsetxattr` at increasing positions.
    - *What the receiver gets:* the attributes describe the compressed bytes, not the plain ones. A digest of the plain
      data, which finding 9 needs, costs the sender a full decompressing read (finding 11). That digest is not known
      until after a header is due, unless it travels as the entry's last blob.

## Method

Standalone C probes built with `clang -O2` (`-lcompression -lz`) and one Swift probe built with `swiftc -O` (Swift 6.4,
swiftlang-6.4.0.34.1) ran from a terminal: account uid 501, no `sudo`. Work went in a scratch folder on the internal
APFS Data volume.

**Reading and the survey.** For each file the probe printed `fstat` (`st_size`, `st_blocks`, `st_flags`), the
`flistxattr` result with options 0 and with `XATTR_SHOWCOMPRESSION`, and each attribute's `fgetxattr` size. It also read
the first 16 bytes of `com.apple.decmpfs` and took the SHA-256 of a full `read(2)`. The survey ran
`find <tree> -xdev -type f -flags +compressed` and read up to 4,096 bytes of each file's `com.apple.decmpfs` with
`getxattr(…, XATTR_SHOWCOMPRESSION | XATTR_NOFOLLOW)`. Files the account cannot read are not counted: 15 under
`/System/Library` and 8 under `/usr`. The type-7 files came from `aa archive -d /usr/share/zoneinfo.default -include-field xat,flg`
and `aa extract`. Layouts were checked by parsing a real file of each type found and decoding it with
`compression_decode_buffer` or Python's `zlib`. For LZVN the probe passed the algorithm value `0x900`, which
`compression.h` does not declare. Each decode was compared with the file's `read(2)` output.

**Recreating.** The probe read both attributes of a source with `XATTR_SHOWCOMPRESSION`. It created the destination with
`open(O_RDWR | O_CREAT | O_EXCL, 0644)`, wrote the attributes in the order under test, and set the flag through
`fchflags`, `fsetattrlist` `ATTR_CMN_FLAGS`, or `ffsctl(FSIOC_CAS_BSDFLAGS)`. For the ioctl it defined the struct and
the constant from XNU's `fsctl.h`. It closed the file, reopened it read-only, and compared `fstat`, the attribute list
and the SHA-256 of a full read with the source. The post-flag steps of finding 4 ran on the creation descriptor, or by
path with `setattrlist(FSOPT_NOFOLLOW)`, or on a second descriptor opened `O_RDWR` or `O_RDONLY`. The file was then
re-read.

**Types and failures.** Files of types 3, 7, 9, 11, 13 and 15 (payload in the attribute) and 8, 10, 12, 14 and 16
(64 KiB chunks) were built from plain text with `compression_encode_buffer` (and zlib `compress2` for type 3) in the
layouts of finding 2. A chunk that did not shrink was stored raw. Unknown and reserved types reused a type-12 file's
attributes with only the type field changed. For types 5, 15 and 16, the payload was re-encoded with each
`libcompression` algorithm in turn. Each corruption in finding 9 changed one field or byte of the source's attributes
before writing them.

**Sandbox.** The probes were linked into one executable inside a minimal app bundle (`CFBundleIdentifier`
`app.kernova.probe.dcsb`). It was signed ad hoc with an entitlements file holding only `com.apple.security.app-sandbox`
and started with `open -W -n --stdout … --stderr …`. The same executable started directly from this session's shell
stopped with `SIGTRAP` in `_libsecinit_appsandbox`, so it was not used that way. The container's contents were deleted
afterwards. `containermanagerd` refused removal of the container's own metadata file.

**Timing.** Wall time came from `CLOCK_MONOTONIC_RAW`. The page cache was not purged, since that needs root. "First
read" means a file recreated by the probe moments before and never read, so its plain pages were not cached. The 1 GiB
source was 108 copies of a 10,000,000-byte text file drawn from `/usr/share/dict/words`, cut to 1,073,741,824 bytes.
The sender comparison read two separate recreated copies of the Frameworks set, so neither had been read before.
For the receiver comparison, both forms of every file were first loaded into memory, and each round wrote them into a
fresh folder, compressed then plain. The folder was removed after each round, followed by `sync` and a 2 s pause.

**exFAT.** `hdiutil create -size 64m -fs ExFAT`, attached with `-nobrowse -mountpoint`, and detached and deleted after
the run. The volume capability came from `fgetattrlist` with `ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES` on a descriptor
inside each volume.

**Archive.** The Swift probe built headers with `ArchiveHeader` fields `TYP`, `PAT`, the blob fields and `DAT` of size 0.
It wrote them with `ArchiveStream.encodeStream` over `compressionStream(using: .lz4)` to a file. It read them back with
`decodeStream.readHeader()` and `readBlob(key:into:)`, then recreated each entry under a fresh folder as in "Recreating".

**Sources read.**
- XNU `main` at `f6217f8` (xnu-12377.1.9):
  - <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/decmpfs.h>
  - <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/decmpfs.c> (`decmpfs_update_attributes`,
    `decmpfs_fetch_compressed_header`, `decmpfs_validate_compressed_file`)
  - <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fsctl.h>
- `copyfile` 240 (`9f91eb6`):
  - <https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.c> (`doesdecmpfs`, `copyfile_xattr`,
    `copyfile_data`, `copyfile_stat`, `copyfile_set_bsdflags`)
  - <https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile_private.h>
- The `copyfile` submodule pinned by `distribution-macOS` tags `macos-115` (`bc4a9c8`) and `macos-1201` (`f71f870`).
- The SDK's `sys/xattr.h`, `sys/stat.h`, `sys/attr.h` and `compression.h`.
- `man 2 getxattr`, `listxattr`, `setxattr` and `chflags`.
