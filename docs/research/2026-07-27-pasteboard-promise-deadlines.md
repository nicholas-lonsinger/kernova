# A lazy pasteboard promise is abandoned by Finder at 60 s and by `dataForType` at 120 s

**Date:** 2026-07-27 · **Host:** macOS 27.0 · **Seam:** a standalone probe
publishing one `NSPasteboardItem` whose `NSPasteboardItemDataProvider` never
returns, read by a Finder paste and by `NSPasteboard.dataForType(_:)`, with
`log stream` capturing the reader's records

## Summary

macOS applies two different deadlines to a lazy pasteboard promise, and Apple
publishes neither number. Both come from the probe:

1. **A Finder paste abandons the promised item at 60.0 s**, logging
   `Finder … [CFPasteboard:general] Finished waiting for promise because timed
   out`. Finder blocks its own main thread for the whole wait, so the user sees
   a 60 s beachball and then nothing pastes.
2. **`NSPasteboard.dataForType(_:)` abandons at 120.0 s**, logging
   `-[NSPasteboard dataForType:]: promise keeping timed out`.
3. **The reader giving up does not cancel the provider.** The `provideData`
   callback runs to completion after the reader has bailed, finishes its
   pull, and caches the representation, so a paste that beachballed and failed
   succeeds at once on the second attempt.

Both log strings, and `-[NSPasteboardItem dataForType:]: promise keeping timed
out`, are present in the macOS 27.0 dyld shared cache.

## Method

1. Publish one item to `NSPasteboard.general` with a data provider whose
   `pasteboard(_:item:provideDataForType:)` sleeps past both deadlines
   before writing, and stamp the wall clock at the call.
2. Paste in Finder; read the `Finder` process's `CFPasteboard` records in
   `log stream` and take the interval from the provider's entry stamp to the
   timed-out record.
3. Repeat with a second process calling `dataForType(_:)` on the same item;
   take the interval to the `promise keeping timed out` record.
4. Let the provider finish; confirm it completes and that the next read of
   the same item returns the cached representation without invoking the
   provider.
5. `strings` on the shared cache for the three log strings.

## What this decides

`ClipboardPasteLimit`'s two deadlines are these two numbers. The provider
callback has to return with the whole payload before the reader abandons it, so
the cap is a byte total — one paste's file representations summed,
all-or-nothing — sized from the tighter deadline through the measured transport
throughput. What it prevents reaches the user as a beachball and an empty paste,
never as an error.
