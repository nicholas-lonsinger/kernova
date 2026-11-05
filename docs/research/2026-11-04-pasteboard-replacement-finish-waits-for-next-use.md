# Another process's replacement is told to a data provider only at the writer's next pasteboard use

**Date:** 2026-11-04 · **Host:** macOS 27.2 (26B123), command-line probes

## Question

When another process replaces a write whose `NSPasteboardItemDataProvider` nothing has finished with, when does
the writer's provider get `pasteboardFinishedWithDataProvider(_:)`? On which thread does AppKit call a provider for
another process's read, and what does a provider call still running when the write is replaced deliver?

## Method

One Swift binary, run as the writer and as helper processes, on a named pasteboard (`NSPasteboard(name:)`, never
the general one). The writer wrote one item promising `public.utf8-plain-text` through a provider, after
`prepareForNewContents(with: .currentHostOnly)` as Kernova writes, and logged each provider call with the time and
`Thread.isMainThread`. Between the steps below it only ran the main run loop (`RunLoop.main.run(until:)`) and
touched no `NSPasteboard` API.

1. **Replacement, no read.** A second process cleared the pasteboard and wrote a string. The writer ran the run
   loop for 10 s, then read `changeCount`, then ran it 3 s more. Run twice.
2. **A read spanning the replacement.** A second process read the promised type; the provider slept 3 s on the
   thread it was called on before setting the data. A third process replaced the write 1 s after the read began.
3. **A read of a replaced write.** A second process took the pasteboard's items, slept 2 s, then read the promised
   type from the item it took; a third process replaced the write 1 s in.

## Observed

1. No finish came in the 10 s the run loop ran untouched. It came, on the main thread, within the `changeCount`
   read (10.063 s and 10.065 s after the write in the two runs; the replacement was at about 0.007 s).
2. The provider was called on the main thread 18 ms after the read began. When it set its data after 3 s, the
   replacement having come at 1 s, `setData(_:forType:)` returned false, and the reader got nil. No finish came in
   the 5 s after; it came within the writer's next `changeCount` read.
3. The provider was never called; the reader got nil. The finish came within the writer's next `changeCount` read.

## Consequence

A replacement by another process reaches a provider only when the writer next uses the pasteboard, however long
that is, so a provider's finish cannot bound how long a replaced write's resources stay held; only polling the
change count does. A provider call for another process's read runs on the main thread, and one still running when
the write is replaced delivers nothing to its reader, nor is a provider asked for a read of a replaced write, so
ending a write's resources once its change count moves loses no paste.
