# CLIPBOARD.md

Read this before designing or extending host↔guest clipboard code. Its
reader is the one about to choose a design; each rule names the option
it makes wrong.

## No Kernova-imposed size bound

The yardstick is native macOS: a copy/paste that works between two apps
on one Mac works host↔guest, at any size, for every representation.
Given a fixed ceiling and a mechanism that removes the need for one — a
spill to disk served back memory-mapped, an archive streamed rather than
staged — build the mechanism; where a representation's bytes live never
decides whether a paste succeeds. The one ceiling that stands is
`ClipboardPasteLimit`: a promised flavor's bytes are pulled inside the
consumer's synchronous provider callback, which the OS abandons on a
deadline nothing can extend, so one paste's file total is bounded and an
over-cap offer is refused whole. That ceiling goes when the pasteboard
gains a promise API that can signal progress, and not before.

## Pay on consume

Bytes cross the boundary only when a destination consumes them — a
paste, or the window's bounded preview. The copy, the offer, a
passthrough publish and the Copy to Mac click move metadata alone. Given
an optimization that reads, hashes, archives or sends a payload earlier
for some subset — a small payload inlined in the offer, a file
pre-staged so the paste is instant — reject it: the wire
(`ClipboardOffer`, `ClipboardRepresentationInfo`) and both ends' promise
tables are built on an offer carrying no bytes, and a path that pays
early for one case is a second data path.
