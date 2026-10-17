# A host drag session swallows the release a VZ guest's drag needs; injected events end it

**Date:** 2026-10-14 · **Host:** M1 Max, 32 GB, macOS 27.2 (26B5112a) · **Guest:** macOS 26.6.2

## Summary

When the host starts its own `NSDraggingSession` partway through a press that
`VZVirtualMachineView` received, the view never gets the physical release. The
drag session consumes the mouse-up, so the guest's left button stays held until
something else sends a release. The guest drag that was in flight stays open.

A constructed `NSEvent` passed straight to `VZVirtualMachineView.mouseUp(with:)`
or `mouseDragged(with:)` reaches the guest at once. The guest logged it within
clock skew of the injection, both after the host session had ended and while it
was still running, and the host session carried on unaffected.

The injected release performs a real drop under the guest pointer. With nothing
of the spike's there, Finder moved the dragged file from `/tmp` to the Desktop,
three times.

A guest window registered for dragged types that appears under the stationary
pointer mid-drag gets no dragging callbacks. The drag manager keeps the
destination it last hit-tested, so a release alone lands on whatever was under
the pointer before the window appeared. One injected 1-px `mouseDragged` before
the release makes the window the destination. It then receives the full
sequence:

1. `draggingEntered`
2. `draggingUpdated`
3. `prepareForDragOperation`
4. `performDragOperation`, carrying the file URL
5. `concludeDragOperation`

Finder offered source mask 55 (copy, link, generic, move, delete). Answering
`.copy` left the source file where it was.

Two more observations:

- `VZVirtualMachineView` receives the gesture as ordinary `mouseDown` and
  `mouseDragged` calls. A local event monitor therefore sees all of it, because
  the view runs no nested tracking loop.
- The guest pointer stays where the last forwarded event put it. It is not
  clamped to the screen edge: x stopped at 998 of 1024.

In the guest, a separate process polling `NSPasteboard(name: .drag).changeCount`
saw each drag start, and no access prompt appeared.

## Method

**Host build.** The spike is PR #1607 (branch `test/drag-out-spike`), built on
`3a5dc610`.

- A `VZVirtualMachineView` subclass logs every mouse event the view receives.
- A local event monitor stashes the mouseDown. When the pointer leaves the view
  with the button held, the spike calls
  `beginDraggingSession(with:event:source:)` from that stashed event, carrying a
  pasteboard type nothing on the host accepts. It swallows the dragged event
  that crossed the edge.
- It then injects events by calling the view's responder methods with events
  from `NSEvent.mouseEvent(with:…)`:

| Run | Commit | Exit edge | Injection |
|---|---|---|---|
| 1 | `36605277` | left (×2) | `mouseUp` at hand-off, while the button is still held |
| 1 | `36605277` | right (×3) | `mouseUp` 3 s after the host session ends |
| 2 | `9b4a5967` | left (×2) | 1 s after hand-off: 1-px `mouseDragged`, then `mouseUp` 0.1 s later |
| 2 | `9b4a5967` | right (×2) | `mouseUp` 1 s after hand-off |

**Guest.** A macOS 26.6.2 VM from the Ephemeral Mode pool with one display and
Kernova's automatic input devices; for a macOS 26 guest that is the Mac
trackpad and keyboard, but this VM's own setting was not checked.

- Run 1's logger is `dragspy.js`. It is JXA under `osascript` and polls
  `NSEvent.pressedMouseButtons`, `NSEvent.mouseLocation` and the drag
  pasteboard's `changeCount` every 10 ms.
- Run 2's helper, `dragcatch`, polls the same values. It adds a 64×64 borderless
  `.floating` `NSPanel`, registered for file URLs, URLs, strings and
  file-promise types. The panel moves under the pointer once the pointer has
  stood still 0.4 s within 80 px of a screen edge during a drag.

**Gesture.** The Tester session drove the host pointer with separate down, move
and up actions in steps of about 20 px. It dragged one Finder file from `/tmp`
in the guest out past the left or right edge of the popped-out display window,
held, and released over empty host desktop.

**Clocks.** Host and guest clocks agreed within 5–45 ms in run 1 and about 2 ms
in run 2.

**Scope.** These results cover only:

- one Finder file that supplies a file URL, and no file promises;
- this host and guest pair;
- the windowed display.

**Raw logs** are in `Spikes/GuestDragOut/results/` on the spike branch, with
the helpers and procedure in its README. Run 2's host log records had expired
before they were captured, so its host timing is the Tester's button log.

## Evidence

Run 1, right exit:

```
host  16:45:32.069 SPIKE exit edge=right 793,537
host  16:45:32.069 SPIKE session begin mode=late
host  (physical release 16:45:34.352; no "SPIKE view up" follows it)
host  16:45:34.907 SPIKE session end op=0 1319,569
host  16:45:38.056 SPIKE view up 771,537 inside=yes synthetic=yes
guest 16:45:38.055 LEFT UP at 998,695
```

Run 1, left exit (button still held until 16:47:50.654):

```
host  16:47:48.303 SPIKE exit edge=left -1,627
host  16:47:48.305 SPIKE view up 10,627 inside=yes synthetic=yes
guest 16:47:48.301 LEFT UP at 13,812
host  16:47:51.211 SPIKE session end op=0 196,659
```

Run 2, guest log:

```
right, release only — no CATCHER lines; Finder moved the file to the Desktop
22:33:14.892  ARMED catcher under pointer at 784,79
22:33:15.559  LEFT UP    at 784,79

left, nudge then release — the file stayed in /tmp
22:34:30.960  ARMED catcher under pointer at 9,79
22:34:31.625  CATCHER draggingEntered  pointer 10,79  sourceMask=55
22:34:31.627  CATCHER draggingUpdated (first)  pointer 10,79
22:34:31.719  LEFT UP    at 10,79
22:34:31.720  CATCHER prepareForDragOperation
22:34:31.722  CATCHER performDragOperation  fileURLs=["/private/tmp/drag-me.txt"]  promises=0
22:34:31.725  CATCHER concludeDragOperation
```

## Platform contracts and prior art

**Apple, Virtualization.**

- Virtualization in the macOS 27.0 SDK has no drag or pasteboard API for macOS
  guests. Its one pasteboard surface is `VZSpiceAgentPortAttachment.sharesClipboard`,
  which serves Linux SPICE guests.
- Apple answered "There isn't an API for that for macOS guests"
  ([forum thread 770818](https://developer.apple.com/forums/thread/770818),
  December 2024).
- The [WWDC26 Virtualization session](https://developer.apple.com/videos/play/wwdc2026/224/)
  adds none.
- `VZVirtualMachineView.h` says the view forwards mouse events to the guest. It
  says nothing about constructed events, so the injection results above are
  observations on this host and guest.

**Apple, AppKit.**

- `NSFilePromiseProvider.h`: `writePromiseToURL:completionHandler:` is
  asynchronous, issued on the provider's operation queue, and states no
  deadline. Contrast the synchronous provider deadline in
  [2026-07-27-pasteboard-promise-deadlines.md](2026-07-27-pasteboard-promise-deadlines.md).
- `NSPasteboard.h` (macOS 15.4+): only the general pasteboard asks on
  programmatic access, and every other pasteboard always allows it.
- `NSEvent.h`: a global event monitor needs Accessibility only for key events.

**Prior art.**

- VMware [open-vm-tools](https://github.com/vmware/open-vm-tools/blob/master/open-vm-tools/services/plugins/dndcp/dndUIX11.cpp),
  guest-to-host drag on Linux guests:
  1. It moves an invisible detection window under the pointer.
  2. It fakes pointer motion so the drag escapes the guest window.
  3. It ends the guest drag with a fake button release.
- [VirtualBox](https://github.com/VirtualBox/virtualbox/blob/main/src/VBox/Frontends/VirtualBox/src/runtime/UIDnDHandler.cpp):
  when the pointer leaves the guest window, the host asks the guest whether a
  drag is pending. It then starts a host drag whose data is fetched only at the
  drop.
