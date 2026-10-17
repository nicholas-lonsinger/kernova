# Guest-to-host drag spike — never merged

Throwaway experiments for dragging a file out of a macOS guest onto the Mac.
The findings and their method are written up in
`docs/research/2026-10-14-vz-guest-drag-handoff.md`; this branch holds the code
and raw logs behind them so a later run can repeat or extend them.

## Host instrumentation

`Kernova/Views/Console/DragOutSpike.swift`, wired in from
`VMDisplayBackingView.swift` (`machineView` is a logging `DragSpyMachineView`).
When a left-button press that began on the display leaves it, the spike starts
its own `NSDraggingSession` from the stashed mouseDown, carrying a pasteboard
type nothing accepts, then injects events into `VZVirtualMachineView`:

| Commit | Exit edge | Injection |
|---|---|---|
| `36605277` (run 1) | left | `mouseUp` immediately at hand-off |
| `36605277` (run 1) | other | `mouseUp` 3 s after the host session ends |
| `9b4a5967` (run 2) | left | 1 s after hand-off: 1-px `mouseDragged`, then `mouseUp` 0.1 s later |
| `9b4a5967` (run 2) | other | `mouseUp` 1 s after hand-off |

Host records: `/usr/bin/log show --predicate 'subsystem == "app.kernova" AND category == "DragOutSpike"' --last 1h`
(all `.notice`, each message starting `SPIKE`).

## Guest helpers

Run inside the guest from Terminal; the project does not build them.

- `guest/dragspy.js` (run 1) logs the guest's left-button state, each new drag
  (drag pasteboard change) and edge contact: `osascript -l JavaScript /tmp/dragspy.js`.
- `guest/dragcatch/main.swift` (run 2) logs the same plus every drag-destination
  callback of a red "CATCH" window that moves under the pointer once it has
  stood still for 0.4 s within 80 px of a screen edge during a drag. Build on the
  host and ship it as text:

  ```sh
  xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -o dragcatch main.swift
  codesign -s - -f dragcatch
  gzip -9 -c dragcatch | base64 -b 76 > dragcatch.b64   # host: pbcopy < dragcatch.b64
  # guest Terminal: cat > /tmp/dc.b64, ⌘V, Control-D, then
  base64 -d -i /tmp/dc.b64 | gunzip > /tmp/dragcatch && chmod +x /tmp/dragcatch && /tmp/dragcatch
  ```

## Running it through the Tester

- Build the commit; use a running macOS guest from the Ephemeral Mode pool with
  Clipboard sharing on and a current guest agent.
- Pop Out Display, not full screen, with empty host desktop on both sides of
  the display window.
- Drag with separate mouse-down, small mouse-move and mouse-up actions, without
  pausing until the pointer is well outside the window. The guest must see
  intermediate movement, and the run-2 helper reads a 0.4 s stop near an edge
  as the hand-off.
- Screen-control typing does not reach the guest: put each command on the host
  pasteboard and paste it into the guest with ⌘V.

## Results

- `results/run1-guest.txt`, `results/run1-host.log`, `results/run1-host-buttons.txt`
- `results/run2-guest.txt`, `results/run2-host-buttons.txt` — run 2's host
  unified-log records had expired before they were captured; its host timing
  is the Tester's button log.
