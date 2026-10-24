# A guest app's file promise names its file the moment it is called in, long before the file is written

**Date:** 2026-10-24 · **Host:** M1 Max, 32 GB, macOS 27.2 (26B118) · **Guest:** macOS 26.6.2 (25G83)

## Summary

A drop destination in a macOS 26.6.2 guest called in file promises from
Photos and Safari. In every drop, `NSFilePromiseReceiver.fileNames` already
held the file's name when `receivePromisedFiles(atDestination:options:operationQueue:reader:)`
returned, 4.0–15.5 ms after the call began. The files finished much later:

| Drag | Name, after the call-in | File written (reader callback) |
|---|---|---|
| Photos photo | 11.5 ms | 441 ms |
| Photos photo, rotated (an edit Photos renders) | 9.8 ms | 1,519 ms |
| Photos 4K video | 8.2 ms | 11,028 ms |
| Three Photos photos together | 4.0, 9.9, 15.5 ms | 337, 376, 523 ms |
| Safari image | 6.0 ms | 262 ms |

Each dragged item was one pasteboard item, one promise receiver and one
file. Three photos dragged together were three of each. `fileTypes` held one
type per receiver, and it named the type of the file actually written: a HEIC
photo declared `public.jpeg` and arrived as `Probe C.jpeg`.

Two more observations:

- Every Photos item also carried a `public.file-url` into the library's own
  derivatives, a JPEG even for the video, as #939 found for Photos on the Mac.
- Photos wrote the video as 233.9 MB from a 110.8 MB original. The export
  re-encodes rather than copies.

Mail was not measured: in a guest with no account, Mail shows its account
sheet instead of the message.

## Method

**Probe.** PromiseProbe, a small AppKit app built for macOS 12 and run in the
guest. Its window registers for `NSFilePromiseReceiver.readableDraggedTypes`
and file URLs. On each drop it:

1. Logs every pasteboard item's types, then each receiver's `fileTypes` and
   `fileNames` before the call-in.
2. Calls each receiver in to a folder of its own under the temporary
   directory, with a serial operation queue for the reader.
3. Logs `fileNames` as each call returns.
4. Polls every 2 ms for changes to any receiver's `fileNames` and for new
   entries in the folder, and logs each reader callback with the file's size.

Every time is measured from the first call-in, on the uptime clock.

**Media.** Generated on the host: 4032×3024 JPEG and HEIC photos, and a 15 s
3840×2160 HEVC movie of noise at 60 Mbps. They were dropped onto the guest's
display and imported into Photos, and one photo was rotated with ⌘R.

**Gestures.** The Tester session dragged each of these onto the probe from the
guest's apps:

- single photos, the rotated photo and the video, from Photos;
- three photos at once, from Photos;
- the article image from `en.wikipedia.org/wiki/Moon`, from Safari;
- a Finder file, as the control: no promise and one file URL.

**Scope.** One guest, Photos and Safari, local photos only (no iCloud
library), and a window destination in the same guest. The probe's source,
media generator and full log are in PR #1681.

## Evidence

```
DROP 3 · source Photos · 1 pasteboard item(s)
  r0 before call-in · fileTypes ["com.apple.quicktime-movie"] · fileNames []
  r0 call-in returned +8.2 ms (call took +8.2 ms) · fileNames ["Probe Video.mov"]
  +11026.7 ms  file appeared: Probe Video.mov (233.9 MB so far)
  +11028.2 ms  r0 reader: Probe Video.mov 233.9 MB

DROP 4 · source Photos · 3 pasteboard item(s)
  r0 call-in returned +4.0 ms · fileNames ["Probe A.jpg"]
  r1 call-in returned +9.9 ms · fileNames ["Probe B.jpg"]
  r2 call-in returned +15.5 ms · fileNames ["Probe C.jpeg"]
  +336.6 ms  r0 reader: Probe A.jpg 354 KB
  +376.0 ms  r1 reader: Probe B.jpg 253 KB
  +522.7 ms  r2 reader: Probe C.jpeg 264 KB

DROP 5 · source Safari · 1 pasteboard item(s)
  r0 before call-in · fileTypes ["org.webmproject.webp"] · fileNames []
  r0 call-in returned +6.0 ms · fileNames ["FullMoon2010.jpg.webp"]
  +15.4 ms  file appeared: FullMoon2010.jpg.webp (186 KB so far)
  +262.4 ms  r0 reader: FullMoon2010.jpg.webp 186 KB
```

## Platform contracts

- `NSFilePromiseReceiver.h`:
  - `fileNames` "returns an empty array until the file promise is called in
    via receivePromisedFilesAtDestination". It says nothing about how soon
    after the call-in the names appear.
  - The count of `fileTypes` "should tell you the number of promised files,
    however, that is not guaranteed": legacy promisers may list a type once and
    write several files.
  - The reader block is called "when the promised file is ready to be read".
- `NSFilePromiseProvider.h`: `filePromiseProvider:fileNameForType:` returns
  the name synchronously ("Do not start writing the file yet"), and the write
  is a separate, asynchronous request.
