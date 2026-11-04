# When `pasteboardFinishedWithDataProvider(_:)` fires

**Date:** 2026-11-04 · **Host:** macOS 27.2 (26B123), a command-line probe

## Question

A pasteboard write's record (`ClipboardStandingWrite`: its source and data) is owned by the write's
`NSPasteboardItemDataProvider`s alone, so it lives as long as AppKit needs them. When does AppKit tell a provider
it is done with it, and does that ever happen while the write still stands?

## Method

A Swift probe wrote one `NSPasteboardItem` promising `public.utf8-plain-text` through a provider to a named
pasteboard (`NSPasteboard(name:)`, never the general one), with `prepareForNewContents(with: .currentHostOnly)`
as Kernova writes, and ran the main run loop while each of these happened:

1. The same process wrote again, then cleared the pasteboard.
2. A second process cleared the pasteboard and wrote a string to it.
3. A second process read the promised type twice, writing nothing.

## Observed

1. The earlier write's provider got `pasteboardFinishedWithDataProvider(_:)` at the next write, and the next at the
   clear.
2. The provider got it once the other process wrote.
3. The provider was asked for the type once, then got `pasteboardFinishedWithDataProvider(_:)`, though the
   pasteboard's change count had not moved: the write still stood, its promised type now data. The second read
   was served from that data without asking the provider again.

## Consequence

The callback ends a write's record when anything replaces the write, and also once every type the write promised
has been provided while it still stands. In the second case nothing is promised any more, so a snapshot that
finds no record and reads the pasteboard's data fires no provider.
