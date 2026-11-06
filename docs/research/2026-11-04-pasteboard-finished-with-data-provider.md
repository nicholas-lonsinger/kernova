# When `pasteboardFinishedWithDataProvider(_:)` fires

**Date:** 2026-11-04 · **Host:** macOS 27.2 (26B123), command-line probes

## Question

When does AppKit tell an `NSPasteboardItemDataProvider` it is done with it, does that ever happen while the write
still stands, and does AppKit keep the provider alive once it has?

## Method

Swift probes wrote to a named pasteboard (`NSPasteboard(name:)`, never the general one), with
`prepareForNewContents(with: .currentHostOnly)` as Kernova writes, and ran the main run loop while each of these
happened:

1. One item promising `public.utf8-plain-text`: the same process wrote again, then cleared the pasteboard.
2. The same item: a second process cleared the pasteboard and wrote a string to it.
3. The same item: a second process read the promised type twice, writing nothing.
4. Two items, the first promising `public.utf8-plain-text` and `public.rtf` through one provider, the second
   `public.file-url` through another: a second process read the first item's text, then its RTF, then the second
   item's file URL, writing nothing.
5. One item promising `public.utf8-plain-text`, its provider held only by the writer's own set, which removes it
   on `pasteboardFinishedWithDataProvider(_:)`, and logging its `deinit`: a second process read the type, and the
   writer then read the item back.

## Observed

1. The earlier write's provider got `pasteboardFinishedWithDataProvider(_:)` at the next write, and the next at the
   clear.
2. The provider got it once the other process wrote.
3. The provider was asked for the type once, then got `pasteboardFinishedWithDataProvider(_:)`, though the
   pasteboard's change count had not moved: the write still stood, its promised type now data. The second read
   was served from that data without asking the provider again.
4. Reading the text asked the first provider for it and did not finish it. Reading the RTF asked for it, then
   finished the first provider. Reading the file URL asked the second provider, then finished it. The change count
   never moved.
5. The provider was asked, got `pasteboardFinishedWithDataProvider(_:)`, and deinitialized once the writer let it
   go, with the change count unmoved; the item still read back the provided text.

## Consequence

AppKit finishes with a provider when anything replaces the write, and also once a reader has had every type that
provider promised while the write stands; reading only some of its types does not finish it. After that AppKit
holds the provider no longer, and the pasteboard serves the provided types as data. So a finish says nothing about
whether the write still stands: only the change count does, and anything the providers alone own goes while the
write may still be on the pasteboard.
