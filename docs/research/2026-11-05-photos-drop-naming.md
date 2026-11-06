# How a drop receives Photos' file promises

**Date:** 2026-11-05 · **Guest:** macOS 27.2, real drags out of Photos, no Kernova code involved

## Question

Why does a drop that calls each of a Photos drag's file promises in through its own `NSFilePromiseReceiver` slow
down as the drag grows, and how fast can a drop receive the same drag?

## Method

Photos held generated photos: 400×300 JPEGs, and a set of 100 at 4032×3024. A probe app took drops of N of them
(N = 100, 1,000) in a window, each drop into a fresh empty folder, and received the promises one of three ways:

- **Per item:** `readObjects(forClasses: [NSFilePromiseReceiver.self])`, then for each receiver
  `receivePromisedFiles(atDestination:options:operationQueue:reader:)` and `fileNames`.
- **Deprecated whole drop:** `NSDraggingInfo.namesOfPromisedFilesDropped(atDestination:)`.
- **HIServices whole drop** (`Pasteboard.h`, "Pasteboard File Promising", steps 4–5): `PasteboardCreate` on the
  drag pasteboard's name, `PasteboardSynchronize`, `PasteboardSetPasteLocation` once with the empty folder, then
  `PasteboardCopyItemFlavorData` for `kPasteboardTypeFileURLPromise` on item 1 alone.

Finder and Notes took the same drags as references. Each run timed the last name ("names") and the moment all N
files were in the folder ("landed"), and logged subsystem `com.apple.CFPasteboard`. Every landed file was compared
with its source byte for byte.

## Observed

| Receiver | 100 | 1,000 |
|---|---|---|
| Finder | names 0.17 s, landed 1.8 s | names 2.2 s, landed 14.8 s |
| Deprecated whole drop | names 0.12 s, landed 1.6 s | names 1.5 s, landed 11.4 s |
| HIServices whole drop | names 0.11 s, landed 1.5 s | names 1.2 s, landed 11.3 s |
| Per item | names 1.7 s, landed 3.3 s | 38 of 1,000 landed; Photos then cancelled the other 962 ("The operation was cancelled.") |
| Notes | 1.9 s | — (Notes refuses the drop: a note holds at most 250 images) |

- **The per-item cost is a cache rebuild per call.** Each receiver call makes its own `SetPasteLocation`, and
  Photos logs `Rebuilding cache` once per call: Notes' 100-photo drop shows 100 of each. The mean gap between two
  names grew from 17 ms at 100 photos to 304 ms at 1,000, so the per-item total grows with the square of N.
- **One ask names the whole drag.** In the HIServices drop, the single read on item 1 had Photos name all N in
  one pass, about 1.1 ms each. Items 2…N return −9, no such flavor, for
  `kPasteboardTypeFileURLPromise`: only item 1 carries the flavor.
- **No deprecation warnings.** The HIServices calls build clean against the Xcode 27.2 SDK.
- **Files appear whole.** Photos writes each export in a container of its own and places the finished file at the
  destination in one step: across 1,300 files, none was seen growing after it appeared.
- **A coordinated read waits for the finished file.** An asynchronous `NSFileCoordinator` read of each file as it
  appeared (`coordinate(with: [.readingIntent(with:)], queue:byAccessor:)`) was granted 20–90 ms after the file
  appeared, never before it had its final size, and every size matched. `NSFilePromiseReceiver`'s own reader
  waits on the same coordination.
- **Polling the folder is costly.** A tight `stat`/xattr loop over the folder made about 213,000 `getxattr` calls
  during one 100-photo drop.
- All landed files, by every method, were byte-identical to their sources.

## Consequence

A drop that calls each promise in pays Photos' cache rebuild once per item, which at 1,000 photos runs long enough
for Photos to cancel the rest. Setting the paste location once and asking item 1's promised file URL once has
Photos deliver the whole drag as fast as Finder receives it; nothing names the files to the receiver except their
arrival in the folder, which a coordinated read confirms finished, and a vnode or FSEvents watch observes without
polling.
