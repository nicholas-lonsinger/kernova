# In a letterboxed VZ display, a guest drag's pointer stays on the nearest point of the guest screen's edge

**Date:** 2026-10-23 · **Host:** macOS 27.2 · **Guest:** macOS 26.6.2

## Summary

With "resize display to fit window" off and the window wider than the VM's
screen, `VZVirtualMachineView` draws the guest screen at its own shape, with
black areas at the sides.

While a guest file drag is in progress and the host pointer moves into a black
area, the guest pointer and the guest's drag image stay on the guest screen,
at the nearest point of its edge. Moving up and down in the black area slides
them along that edge. They never leave the guest desktop.

When the host pointer leaves the black area for the sidebar or the rest of the
host, the guest pointer stops moving, and the drag image stays where it was.

A drag hand-off that nudges the guest pointer at the point where the drag left
the view, held 8 points inside the view, then one point from there toward the
view's center, got the guest's catcher to take the drag. The drag image stayed
by the edge, and the copy to the Mac completed. This held in the letterboxed
window and full screen.

This is an observation on one host and guest pair. `VZVirtualMachineView.h`
documents no mapping for points outside the guest screen.

## Method

**Host build.** A spike of Kernova's drag-out hand-off, commit `fb10a82c`.
`VMDisplayMachineView.nudgePoint(_:)` puts the first nudge at the exit point
clamped 8 points inside the view's bounds, and the next one point from it
toward the view's center on each axis.

**Window.** One VM display with "resize display to fit window" off, in a window
wider than the VM's screen, so the view letterboxes the guest screen at its
sides; then the same VM full screen.

**Gesture.** The maintainer dragged a file from the guest desktop into a black
area, moved up and down there, then out of the view to the sidebar and the
host, and dropped it on the Mac.

**Observed** by eye on the guest screen and the host: where the guest pointer
and drag image sat, whether the catcher took the drag, and whether the file
arrived on the Mac.

**Scope.** These results cover only:

- this host and guest pair;
- a drag of a file;
- a letterbox at the sides of the guest screen, and full screen.
