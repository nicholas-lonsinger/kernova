# Swift LZ4 against COMPRESSION_LZ4_RAW: block throughput per corpus and core count

**Date:** 2026-11-02 · **Hardware:** M1 Max (MacBookPro18,4, 8 performance and 2 efficiency cores), 32 GB, macOS
27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2 · **Power:** AC with Low Power Mode on; the machine was shared with
other agents' builds and tests (load in the method)

## Summary

1. **`LZ4Block` now encodes at 0.70–0.75 of Apple's rate on code and text and 0.49–0.55 on binaries, and decodes
   at 0.58–0.71 of Apple's.** Median over 25 pairs of the per-pair ratio, Swift's rate over Apple's on the same
   blocks, with the interquartile range; 256 KiB blocks:

   | Corpus | Op | 1 thread | 2 | 4 | 10 |
   |---|---|---|---|---|---|
   | Code | encode | 0.721 [0.699–0.729] | 0.718 [0.696–0.722] | 0.721 [0.702–0.725] | 0.745 [0.715–0.789] |
   | | decode | 0.610 [0.609–0.615] | 0.614 [0.612–0.622] | 0.618 [0.617–0.620] | 0.606 [0.595–0.618] |
   | Text | encode | 0.728 [0.725–0.732] | 0.728 [0.727–0.732] | 0.723 [0.720–0.725] | 0.701 [0.697–0.704] |
   | | decode | 0.706 [0.704–0.707] | 0.706 [0.705–0.706] | 0.706 [0.706–0.707] | 0.680 [0.674–0.688] |
   | Binaries | encode | 0.547 [0.435–0.601] | 0.485 [0.437–0.570] | 0.494 [0.445–0.568] | 0.500 [0.478–0.557] |
   | | decode | 0.592 [0.554–0.602] | 0.601 [0.591–0.604] | 0.586 [0.578–0.603] | 0.579 [0.575–0.583] |
   | Media | encode | 10.625 [9.974–11.045] | 9.850 [9.595–10.249] | 9.372 [8.679–9.828] | 9.366 [7.755–9.857] |
   | | decode | 0.888 [0.884–0.894] | 0.876 [0.858–0.891] | 0.862 [0.845–0.879] | 0.833 [0.818–0.851] |
   | Zeros | encode | 0.340 [0.339–0.341] | 0.367 [0.359–0.369] | 0.378 [0.371–0.380] | 0.459 [0.442–0.479] |
   | | decode | 37.280 [36.438–37.364] | 33.263 [32.210–42.608] | 27.330 [25.855–37.482] | 19.333 [18.995–20.402] |

   The median rates behind them, Swift / Apple, in GiB/s of uncompressed bytes:

   | Corpus | Op | 1 thread | 2 | 4 | 10 |
   |---|---|---|---|---|---|
   | Code | encode | 0.548 / 0.757 | 1.074 / 1.506 | 2.063 / 2.904 | 4.918 / 6.582 |
   | | decode | 1.861 / 3.036 | 3.631 / 5.928 | 7.604 / 12.296 | 16.563 / 27.666 |
   | Text | encode | 0.269 / 0.369 | 0.536 / 0.736 | 1.058 / 1.464 | 2.389 / 3.409 |
   | | decode | 1.028 / 1.454 | 2.052 / 2.909 | 4.098 / 5.800 | 9.005 / 13.278 |
   | Binaries | encode | 0.328 / 0.607 | 0.580 / 1.190 | 1.227 / 2.456 | 2.681 / 5.495 |
   | | decode | 1.647 / 2.742 | 3.294 / 5.466 | 6.207 / 10.754 | 14.824 / 25.556 |
   | Media | encode | 11.197 / 1.057 | 20.724 / 2.104 | 38.517 / 4.192 | 81.799 / 8.561 |
   | | decode | 23.219 / 26.158 | 44.971 / 51.073 | 83.107 / 95.709 | 170.161 / 205.953 |
   | Zeros | encode | 5.722 / 16.842 | 11.081 / 30.218 | 21.738 / 58.140 | 43.390 / 94.032 |
   | | decode | 17.791 / 0.478 | 31.743 / 0.954 | 52.245 / 1.909 | 86.544 / 4.491 |

   - *Scaling:* both codecs scale close to linearly to four threads. At ten, two of them efficiency cores and
     all of them shared with other processes, the ratio stays within 0.03 of its one-thread value on code and
     text, and within its spread on binaries.
   - *Media:* Swift's encoder gives up on a block that will not shrink at 11.2 GiB/s per core, about 0.09
     core-seconds per GiB; Apple's takes 1.06 GiB/s, about 0.95. Only 32 of the 1,024 media blocks shrink, so
     media decode times those 32.
   - *Zeros:* Apple encodes zeros 3× faster than Swift, and decodes Swift's zero blocks, one offset-1 match each, at
     0.48 GiB/s per core.
2. **Before this change `LZ4Block` encoded at 0.40–0.51 of Apple's rate and decoded at 0.19–0.24.** The same bench
   over the codec as it stood at `323172e7`, run first in the same session:

   | Corpus | Encode ratio, 1 / 10 threads | Decode ratio, 1 / 10 threads | Swift encode, 1 thread | Swift decode, 1 thread |
   |---|---|---|---|---|
   | Code | 0.478 / 0.467 | 0.227 / 0.239 | 0.364 GiB/s | 0.696 GiB/s |
   | Text | 0.512 / 0.497 | 0.218 / 0.222 | 0.189 GiB/s | 0.317 GiB/s |
   | Binaries | 0.425 / 0.399 | 0.195 / 0.211 | 0.263 GiB/s | 0.562 GiB/s |
   | Media | 9.488 / 7.768 | 0.434 / 0.440 | 9.995 GiB/s | 11.199 GiB/s |
   | Zeros | 0.053 / 0.081 | 1.001 / 1.002 | 0.890 GiB/s | 0.478 GiB/s |

3. **Each change, by its single-thread ratio.** Development runs of 7 pairs, applied in this order; the
   encoder's output stayed byte-identical throughout (the per-corpus digest of every encoded block did not change):

   | Change | Effect |
   |---|---|
   | Encoder: extend a match forward a word at a time, the first differing byte found by trailing zero bits | Encode, text 0.51 → 0.67, code 0.48 → 0.65, zeros 0.05 → 0.32 |
   | Encoder: scratch output uninitialized instead of zero-filled, copied out once | Text unchanged; zeros at 10 threads 8 → 49 GiB/s |
   | Encoder: hash table in `withUnsafeTemporaryAllocation` instead of an `Array` | Encode, text 0.67 → 0.73 |
   | Decoder: literals of up to 16 bytes and matches with an offset of 8 or more copied 8 bytes at a time with a bounded overshoot, an overlapping match repeated by doubling copies, output uninitialized | Decode, text 0.22 → 0.63, code 0.23 → 0.50, zeros 1.0 → 37 |
   | Decoder: a match of up to 18 bytes with an offset of 8 or more copied as a fixed 24 bytes | Decode, text 0.63 → 0.71, code 0.50 → 0.58 |
   | Decoder: longer matches with an offset of 16 or more copied 16 bytes at a time | Decode, code 0.58 → 0.61, binaries 0.57 → 0.59 |

   Two variants measured worse and were not kept: 16-byte copies for every match with an offset of 16 or more,
   short ones included, in place of the fixed 24 bytes (text decode 0.63 → 0.56), and literals of up to 16 bytes
   copied a word at a time in the encoder (text encode 0.73 → 0.68).
4. **The two codecs' blocks interoperate and compress alike.** Every block each codec wrote decoded through both to
   the original bytes. Output over input, a block that does not shrink counted at its raw size:

   | Corpus | Swift | Apple |
   |---|---|---|
   | Code | 0.228 | 0.231 |
   | Text | 0.552 | 0.559 |
   | Binaries | 0.443 | 0.459 |
   | Media | 0.999 | 0.999 |
   | Zeros | 0.004 | 0.004 |

5. **With the Swift codec, two encoding cores raise guest → host throughput only on code-like payloads, and the
   receiver's single-thread decode caps every gain.** This is
   [the costs note's finding 9](2026-10-26-decmpfs-pass-through-costs.md) recomputed: throughput is
   min(encode at *n* threads, decode on one thread, link ÷ ratio) over a ~750 MiB/s link, with encode measured at
   *n* threads rather than multiplied. Decode is one thread because `ContainerDecoder` is fed one record at a time.
   Like finding 9, it assumes a guest vCPU runs at a host core's rate:

   | Payload | Codec | 1 core | 2 cores | 4 cores | Single-thread decode caps the gain at |
   |---|---|---|---|---|---|
   | Code | Swift, now | 0.75× | 1.47× | 2.54× (decode-bound) | 2.54× |
   | | Swift, before | 0.50× | 0.95× (decode-bound) | 0.95× (decode-bound) | 0.95× |
   | | Apple | 1.03× | 2.06× | 3.97× | 4.15× |
   | Text | Swift, now | 0.37× | 0.73× | 1.40× (decode-bound) | 1.40× |
   | | Swift, before | 0.26× | 0.43× (decode-bound) | 0.43× (decode-bound) | 0.43× |
   | | Apple | 0.50× | 1.00× | 1.79× (link-bound) | 1.99× |
   | Binaries | Swift, now | 0.45× | 0.79× | 1.68× | 2.25× |
   | | Swift, before | 0.36× | 0.65× | 0.77× (decode-bound) | 0.77× |
   | | Apple | 0.83× | 1.62× | 2.18× (link-bound) | 3.74× |

   - *For P9:* the "at least two encoding cores" threshold holds for code-like payloads only. Text and binaries
     break even between two and three cores, from the single-thread rates three cores give text 1.10× and
     binaries 1.34×, and gain 1.40× and 1.68× at four.
   - *The cap:* past four cores the receiver's one decoding thread, not the encoder, bounds the gain on code
     and text. Raising it means decoding on more than one thread on the host.
   - *Before this change* the decoder alone held every payload under 1×, at any number of encoding cores.

## Method

**Bench.** `kernova-bench lz4`, the `KernovaBench` target in `KernovaKit`, built with
`swift build -c release --product kernova-bench` (Xcode's toolchain). "Before" is the binary built at
`3f56c74c`, the bench over the codec of `323172e7`; "now" is `126bd010`.

- *Blocks:* each corpus file was read whole and cut into 256 KiB blocks, the plan's chunk size; the last block
  of a corpus is shorter.
- *Check before timing:* each block was encoded by both codecs, and each encoded block decoded through both and
  compared with the original. A digest (FNV-1a) of every Swift-encoded block is printed per corpus.
- *Swift:* the public `LZ4Block.compress(_:)` and `decompress(_:decompressedSize:ceiling:)`, each call's
  allocation of its result included, as `ContainerEncoder` and `ContainerDecoder` call them.
- *Apple:* `compression_encode_buffer` and `compression_decode_buffer` with `COMPRESSION_LZ4_RAW`, each thread
  writing into its own preallocated buffer with its own scratch buffer. Encode was given one byte less than the
  block, the room `LZ4Block` gives itself, so both give up on a block that would not shrink.
- *Decode input:* both codecs decoded the same blocks, those `LZ4Block` shrank. That is what a Kernova receiver
  decodes.
- *Rate:* uncompressed bytes over wall time.

**Samples.** Each cell ran one untimed pair and then 25 timed pairs, each pair one sample per codec.

- *Pairing:* within a pair both codecs took the same blocks; even pairs ran Swift first, odd pairs Apple first.
  The pair's ratio is Swift's rate over Apple's. Medians and interquartile ranges are nearest-rank.
- *A sample:* *n* threads from `DispatchQueue.concurrentPerform`, taking blocks from a shared counter until the
  sample's share is done. The share was 8 MiB per thread for encode and 32 MiB for decode. Successive pairs moved
  through the corpus, wrapping at its end.
- *Runs:* the full sweep (five corpora; 1, 2, 4 and 10 threads) ran four times, in the order before, now,
  before, now. The tables give the first run of each. On code, text and binaries the two "now" runs' ratio
  medians agree to within 0.02, except code encode at ten threads (0.745 against 0.697).

**Corpora.** Each concatenates the files of a sorted walk:

- *Code:* the first 128 MiB of the SDK's `usr/include` and `System/Library/Frameworks` `.h`, `.c`, `.m`,
  `.swift` and `.swiftinterface` files (9,618 files).
- *Text:* `/usr/share/dict` and this repository's `docs/` Markdown (68 files, 3.9 MB), repeated to 64 MiB. The
  repeats lie beyond LZ4's 64 KiB window.
- *Media:* the first 256 MiB of the `.heic`, `.mov`, `.jpg` and `.png` files in `/System/Library/Desktop
  Pictures` (152 files).
- *Binaries:* the first 256 MiB of the toolchain's `usr/lib` `.dylib`, `.a` and `.so` files (57 files).
- *Zeros:* 64 MiB, made by the bench (`zeros=67108864`).

**Load.** `uptime` before each corpus set read 1-minute load averages of 2.4–3.5 for the first run and 5.4–10.0
for the other three. The noise moved the absolute rates and left the ratios:

- In the second "before" run, text at four threads gave Apple 0.66 GiB/s against 1.46 in the first, while the
  ratio's median moved from 0.511 to 0.556 and its spread widened to [0.445–0.695].
- So the absolute figures are this host's, under Low Power Mode and that load. They are not guest rates, and
  P9 re-measures in guests. The ratios are the finding.
- The bench records `getloadavg` before and after each corpus where the platform has it.

**Linux build.** The same target builds as a static aarch64 musl executable with the Static Linux SDK
`Tools/build-linux-guest-agent.sh` uses:
`swiftly run swift build +<.swift-version> --package-path KernovaKit --scratch-path KernovaKit/.build/swiftly
--swift-sdk <static SDK id> --triple aarch64-swift-linux-musl -c release --product kernova-bench`.
Off Apple platforms the bench times `LZ4Block` alone, as there is no `Compression`.
