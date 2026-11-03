# Transfer compression policy: the container codec's LZ4 pipeline in guests, and where it beats plain bytes

**Date:** 2026-11-03 · **Host:** M1 Max (MacBookPro18,4, 8 performance and 2 efficiency cores), 32 GB, macOS 27.2
(26B123) · **Guests:** Ubuntu 26.04.1 LTS at 1, 2, 4, 5 and 6 vCPUs and macOS 27.2 (26B123) at 1, 2 and 4, pool guests ·
**Build:** `kernova-bench` at `ad46d0b5`, and at `f4546c2a` for the Linux runs at 4, 5 and 6 vCPUs

## Summary

1. **In a guest, the LZ4 pipeline's encode scales with the guest's vCPUs: 2.9–3.0× on 4 lanes of a Linux guest
   and 3.5–3.6× on a macOS guest. Extra lanes on fewer vCPUs gain nothing.** Encode rates in MiB/s of input,
   lanes equal to vCPUs, which is what `TransferCompression.forSending` runs:

   | Corpus (ratio) | Linux 1 vCPU | 2 | 4 | macOS 1 vCPU | 2 | 4 | Host, 4 lanes | 8 lanes |
   |---|---|---|---|---|---|---|---|---|
   | Code (0.234) | 477 | 841 | 1,442 | 485 | 963 | 1,819 | 1,929 | 3,450 |
   | Text (0.552) | 238 | 433 | 716 | 242 | 497 | 945 | 1,014 | 1,731 |
   | Binaries (0.401) | 294 | 537 | 917 | 287 | 568 | 1,061 | 1,086 | 2,035 |
   | Media (0.995) | 1,863 | 1,960 | 1,974 | 1,716 | 2,335 | 2,404 | 2,341 | 2,248 |

   - *Scaling at 4 vCPUs:* the 4-lane rate over the 1-lane rate in the same guest is 2.91 (code), 2.90 (text)
     and 3.02 (binaries) on Linux, against 3.50, 3.60 and 3.53 on macOS. The Linux shortfall is the same on every
     corpus, so it is a trend, not a noisy cell.
   - *Lanes past the vCPUs:* on 1 vCPU, 2 and 4 lanes encode within 4% of 1 lane on code, text and binaries on
     both OSes. On a Linux guest at 2 vCPUs, 2 lanes give 841 MiB/s on code where 2 lanes at 4 vCPUs give 977.
     The caller's own thread takes a share of the vCPUs.
   - *A lane on every vCPU, at 5 and 6:* on the Linux guest at 6 vCPUs, 5 lanes beat 6 lanes on code (2,192
     against 2,065 MiB/s), text (1,180 against 1,038) and binaries (1,362 against 1,270), by 6–14%. At 5 vCPUs, 4
     lanes against 5 is mixed: −2%, −5% and +3% for 5 lanes.
     - The direction at 6 is the same on all three corpora, and the Linux 4-vCPU run repeats within 4.5% (finding
       2), so this reads as the caller's thread contending with the lanes for the vCPUs rather than as noise.
     - It is one run per count. No run measured fewer lanes than vCPUs below 5.
   - *Against the guest's vCPUs, a macOS guest runs at 0.93–0.98 of the host's 4-lane rate, and a Linux guest at
     0.71–0.84.*
   - *The plain path* encodes at 2,254 MiB/s or more in every guest cell but two macOS 1-vCPU cells (code 1,031,
     media 1,390). The host decodes plain bytes at 2,810 MiB/s or more. Plain bytes are therefore link-bound at
     every point measured.

2. **Compression beats plain bytes on every compressible corpus measured from 5 vCPUs up. At 4, a Linux guest
   loses on text (0.95× and 0.98× in two runs), though a macOS guest wins on every corpus there. So
   `minimumEncodingCores` is 5.**
   - *The model:* throughput is min(guest encode, link ÷ ratio, host decode) with compression, and min(guest plain
     encode, link, host plain decode) without. The link is ~750 MiB/s guest → host, as
     [the vsock transport note](2026-07-13-vsock-transport-throughput.md) measured it (summary table, "Raw vsock,
     stock"). [#1694](https://github.com/nicholas-lonsinger/kernova/issues/1694) asks whether more connections
     raise it.
   - *Rates are the measured medians.* Guest encode is at lanes = vCPUs. Host decode is at 4 lanes; the last
     column instead decodes in the caller, as `ContainerDecoder` alone did. The Linux rows at 4 (second run), 5
     and 6 vCPUs are from the `f4546c2a` build:

   | Guest | vCPUs | Code | Text | Binaries | Media | Text, host decode in caller |
   |---|---|---|---|---|---|---|
   | Linux | 1 | 0.64× | 0.32× | 0.39× | 1.01× | 0.32× |
   | | 2 | 1.12× | 0.58× | 0.72× | 1.01× | 0.58× |
   | | 4 | 1.92× | **0.95×** | 1.22× | 1.01× | 0.95× |
   | | 4, second run | 1.90× | **0.98×** | 1.17× | 1.01× | 0.98× |
   | | 5 | 2.32× | 1.18× | 1.49× | 1.01× | 1.18× |
   | | 6 | 2.75× | 1.38× | 1.69× | 1.01× | 1.18× |
   | macOS | 1 | 0.65× | 0.32× | 0.38× | 1.01× | 0.32× |
   | | 2 | 1.28× | 0.66× | 0.76× | 1.01× | 0.66× |
   | | 4 | 2.43× | 1.26× | 1.41× | 1.01× | 1.18× |

   - *Every compressed cell is guest-encode-bound,* except media, which is link-bound at 754 MiB/s (750 ÷ 0.995).
     The guest's encode rate on text, the slowest compressible corpus, decides the threshold: it must exceed 750
     MiB/s on both OSes.
   - *The deciding rows*, Linux text encode on as many lanes as vCPUs:
     - 4 vCPUs: 716 and 737 MiB/s, short of the link in both runs.
     - 5 vCPUs: 888 MiB/s, 18% above it.
     - 6 vCPUs: 1,038 MiB/s.

     Code and binaries already win at 4 (1,424–1,442 and 876–917 MiB/s).
   - *Noise against margin:* the two Linux 4-vCPU runs, on different builds, agree within 4.5% on every corpus:
     code 1,442 → 1,424, text 716 → 737, binaries 917 → 876. Five's 18% text margin is four times that. It is one
     run, and the bench leaves out the reader's and the transport's CPU (Method).
   - *Plain stays link-bound with the decoder's copy (`f4546c2a`).*
     - Guest plain encode is 2,379–2,602 MiB/s.
     - The host's plain decode before the copy was ≥ 2,810 MiB/s. On the same host after it, 2,869–3,093 MiB/s,
       from PR #1804's alternating runs.
     - The guest's own plain decode fell 13–15%, to 3,974–4,066 MiB/s, which shows the copy's cost; a guest →
       host transfer does not decode in the guest.

3. **At the host's per-core rates, eight lanes put every compressible corpus past link ÷ ratio, so more lanes
   cannot raise throughput.**
   - *The host, 8 lanes:* code 3,450 MiB/s against 3,205; text 1,731 against 1,359; binaries 2,035 against
     1,870.
   - *A Linux guest* that kept its 4-vCPU fraction of the host's rate (0.75, 0.71, 0.84) would encode about 2,578,
     1,222 and 1,718 MiB/s on 8 lanes. That is short of link-bound, so the cap of 8 can hold a Linux guest with
     more than 8 vCPUs below the link's rate, though still above plain bytes. Neither case was measured in a guest.
   - `maximumEncodingWorkers` is 8. The 5- and 6-vCPU runs in finding 1 do not move it: a cap of 8 only binds
     above 8 vCPUs. What they bear on is the lane count below the cap, one per vCPU. At 6 vCPUs a lane fewer
     encoded faster, which the policy does not take up on one run.

4. **With entries abandoning LZ4 after 4 unshrunk chunks, media never holds a transfer below the link, and costs
   0.10–0.19 CPU seconds per GiB more than plain bytes in the caller.**
   - *Throughput:* media encodes at 1,408 MiB/s or more in every guest cell and at any lane count; 1,408 is macOS
     1 vCPU on 4 lanes. Its compressed throughput is the link's, 754 against 750.
   - *CPU, in the caller:* encode CPU over the plain path is 0.520–0.531 against 0.402–0.404 s/GiB (Linux), and
     0.465–0.520 against 0.307–0.377 (macOS).
   - *CPU, lanes = vCPUs:* the cost rises to 0.55–0.68 s/GiB, from attempts a lane starts before the entry gives
     up.
   - *Not measured:* no run varied `--abandon-after`, so whether another value saves CPU is untested. 4 is kept
     because it cannot lower throughput.

5. **Four decoding lanes on the host decode every compressible corpus at 1.98× link ÷ ratio or more. In
   the caller alone, the host would cap every one below it.** Host decode, MiB/s, against link ÷ ratio:

   | Corpus | Link ÷ ratio | In caller | 2 lanes | 4 lanes | 8 lanes |
   |---|---|---|---|---|---|
   | Code | 3,205 | 1,686 (0.53) | 3,480 (1.09) | 6,353 (1.98) | 7,652 (2.39) |
   | Text | 1,359 | 885 (0.65) | 1,968 (1.45) | 3,756 (2.76) | 4,235 (3.12) |
   | Binaries | 1,870 | 1,417 (0.76) | 3,137 (1.68) | 4,950 (2.65) | 5,705 (3.05) |

   - *Two lanes are not enough.* They leave code 9% above its link-bound rate, a margin the guest's own vCPUs
     competing for host cores could take.
   - *Eight lanes* add 20% on code and nothing the link can use.
   - `maximumDecodingWorkers` is 4.
   - *Decoding in the caller* would already bind text on the 4-vCPU macOS guest, 1.18× against 1.26×, and on the
     6-vCPU Linux guest, 1.18× against 1.38×.

## Method

**Bench.** `kernova-bench pipeline`, the `KernovaBench` target in `KernovaKit`, at `ad46d0b5` for every run but
the Linux runs at 4, 5 and 6 vCPUs, which ran at `f4546c2a`.

- *What `f4546c2a` changed:* the decoder copies each chunk's bytes out of the feed it arrived in. Encode is
  unchanged.

- *Builds:*
  - Linux guest: built statically for aarch64 musl with the Static Linux SDK `Tools/build-linux-guest-agent.sh`
    uses (`swiftly run swift build +6.4.1 --swift-sdk swift-6.4.1-RELEASE_static-linux-0.1.0 --triple
    aarch64-swift-linux-musl -c release --product kernova-bench`).
  - macOS guest and host: `swift build -c release --product kernova-bench` with Xcode's toolchain.
  - The commands are in PR #1804's body.
- *What a cell is:*
  - Each corpus becomes a folder of 4 MiB files, its events cut into 256 KiB chunks as `TreeReader` cuts them.
  - Each runs three ways: plain storage through `ContainerEncoder` and `ContainerDecoder`; LZ4 storage through
    them in the caller; and LZ4 storage through `ContainerEncodePipeline` and `ContainerDecodePipeline` on each
    lane count.
  - Decoding feeds the container in 1 MiB pieces, the raw DATA maximum.
  - The policy abandons an entry after 4 unshrunk chunks.
  - Every path's decoded bytes were checked against the corpus before timing.
- *Sampling and units:*
  - One untimed run, then five timed runs per cell. Each column's median is reported separately.
  - Rates are uncompressed MiB per wall second.
  - CPU is the process's user and system time (`getrusage`), every thread's, per GiB of input.
- *What the bench leaves out:* the bench times the codec alone. Reading the files and writing to vsock cost the
  guest CPU in a real transfer, and the model in finding 2 leaves them out. Plain bytes pay the transport on four
  times as many bytes as code compressed.

**Runs.**

- *Guests:* `kernova-bench pipeline --workers 1,2,4 code=code text=text binaries=binaries media=media
  zeros=67108864`, in each guest at 1, 2 and 4 vCPUs, over SSH.
- *The Linux guest again:* the same with `--workers 4,5,6`, at 4, 5 and 6 vCPUs.
- *Host:* the same with `--workers 1,2,4,8`, on the host, the guests idle.
- *The tables:* the tester's files `linux-{1,2,4}vcpu.md`, `macos-{1,2,4}vcpu-rerun.md`, `host.md` and
  `linux-{4,5,6}vcpu-f454.md`.

**Corpora.** Built on the host as the PR body gives, and copied into each guest:

- *Code:* the first 64 MiB of the SDK's `usr/include` and `System/Library/Frameworks` `.h`, `.swiftinterface`, `.c`
  and `.m` files, in sorted order.
- *Text:* `/usr/share/dict` and this repository's `docs/` Markdown, repeated to 32 MiB.
- *Binaries:* the first 64 MiB of the Xcode toolchain's `usr/lib` `.dylib`, `.a` and `.so` files.
- *Media:* the first 64 MiB of `/System/Library/Desktop Pictures` `.heic`, `.jpg`, `.png` and `.mov` files.
- *Zeros:* 64 MiB, made by the bench. They are zero runs throughout, with no chunk work, and appear in no finding.
- *Coverage:* the corpora hold no payload with a ratio between text's 0.55 and media's 0.995 that encodes more
  slowly than text. Such a payload still loses at 5 vCPUs whenever it encodes below 750 MiB/s, and the adaptive
  skip does not catch it, since its chunks shrink.

**Load and noise.**

- *The host:* its 1-minute load average was about 2 throughout, from a source nobody traced. Before each run it
  read: Linux 1/2/4 vCPUs 2.57 / 2.16 / 1.83; the macOS reruns 1/2/4 vCPUs 1.39 / 2.23 / 1.93; the host's own
  run 2.03.
- *The macOS guest:*
  - The first macOS runs started while the guest's 1-minute load was still high (9.7, 53 and 48). This note uses
    the reruns, which waited until it fell below 2, though the guest's 5-minute load was still 11–14.
  - Between the two sets, the median cell moved by less than 3% at each vCPU count. But 14 of 120 cells moved by
    more than 10%, mostly at 1 and 2 vCPUs, plain-path cells among them.
  - Single cells at 1 and 2 vCPUs are noisy. The macOS 1-vCPU plain encode of code (1,031 MiB/s) and of media
    (1,390) are two such cells. Each finding rests on trends across corpora and lane counts, not on one cell.
- *Linux and the host* were each run once. The Linux runs started with the guest's 1-minute load at 1.59, 0.88
  and 0.47.
- *The Linux runs at 4, 5 and 6 vCPUs* (`f4546c2a`) were each run once, with no other build or test running.
  - Host load before each (1/5/15 minutes): 2.53 / 3.38 / 4.48, 1.94 / 3.04 / 4.26, and 1.60 / 2.72 / 4.04. The
    5- and 15-minute loads were still falling from the tester's builds just before.
  - The guest's 1-minute load: 0.37, 1.04 and 0.44.
  - With one run per count, noise between neighbouring counts shows only through the 4-vCPU repeat (finding 2).
- *The link and the host's decode:*
  - The link figure is a single stream from a macOS 26 guest at 4 vCPUs. No Linux guest's vsock rate has been
    measured.
  - The host's decode rates were measured with the guests idle. In a transfer, the sending guest's vCPUs run on
    the same host cores.
