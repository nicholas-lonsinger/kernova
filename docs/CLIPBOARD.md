# CLIPBOARD.md

Read this before designing or extending host↔guest clipboard code.

## No Kernova-imposed size bound

A copy/paste that works between two apps on one Mac works host↔guest, at
any size. Given a fixed ceiling and a mechanism that removes the need for
one — a spill to disk served back memory-mapped, a container streamed
rather than staged — build the mechanism. The one ceiling,
`ClipboardPasteLimit`, stands on a platform deadline: a promised flavor's
bytes are pulled inside the consumer's synchronous provider callback, a
wait the consumer abandons.

## Pay on consume

Bytes cross the boundary only when a destination consumes them: a paste,
or a clipboard command, which takes at the click everything of one side's
clipboard but its files. The source's own disk is paid the same way: a
file iCloud Drive or another File Provider evicted is downloaded by the
pull that reads it (`DatalessMaterialization`). Given an optimization
that reads, hashes, archives or sends a payload earlier for some subset —
a small payload inlined in the offer, a file pre-staged so the paste is
instant — reject it: a path that pays early for one case is a second data
path.
