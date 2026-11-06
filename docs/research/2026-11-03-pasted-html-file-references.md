# Pasted HTML's `file:` image references: Mail and Notes load neither

**Date:** 2026-11-03 · **Host:** macOS 27.2, run by hand by the maintainer

## Question

Does a host app load a `file:` image referenced from HTML pasted into it? Kernova's clipboard gate passes HTML
through as content, so an app that did would read a local file named by the far side's HTML. Only a real paste into
a WebKit editor answers this.

## Method

1. Make a local image:
   `sips -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns --out /tmp/kernova-canary.png`
2. Put `<p>canary:</p><img src="file:///tmp/kernova-canary.png">` on the general pasteboard as `public.html`, and
   `canary` as `public.utf8-plain-text`, with `osascript -l JavaScript` and `NSPasteboard.setStringForType`.
3. Paste with ⌘V into a new Mail message, then into a new note in Notes.

## Observed

- **Mail** showed only "canary:", with no image and no placeholder.
- **Notes** showed "canary:" and a broken-image placeholder, a blue "?" box.
- Neither loaded the local file.

## Consequence

For Mail and Notes on macOS 27.2, the clipboard gate needs no rule for `file:` references inside HTML.
