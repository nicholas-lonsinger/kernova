# Guest file-promise probe (#1626 spike, do not merge)

PromiseProbe is a drop target for a macOS guest. It calls in the file promises
of each drop and times what `NSFilePromiseReceiver` reports, measured from the
first call-in:

- when each receiver's `fileNames` fills in;
- when files appear in the destination folder;
- when each reader callback fires.

## Build

`./build.sh` writes `build/Promise Probe/`. That folder holds `PromiseProbe.app`,
built for macOS 12 and ad-hoc signed, and the test media:

- three 4032×3024 photos, two JPEG and one HEIC;
- a 15 s 3840×2160 HEVC movie of noise;
- `Probe Mail.eml`, a message carrying a PDF and a PNG attachment.

## Procedure

1. Drop `Promise Probe` onto a VM's display.
2. In the guest, open `PromiseProbe.app`.
3. Import the media into Photos, and rotate one photo with ⌘R.
4. Drag items from Photos, Safari and Finder onto the probe's window.
5. **Copy All** puts the log on the clipboard. The probe also appends it to
   `~/Library/Logs/PromiseProbe.log`.

## Results

`results/probe-log.txt` is the run of 2026-10-24 in a macOS 26.6.2 guest.
`docs/research/2026-10-24-guest-file-promises-name-at-call-in.md` records the
finding.
