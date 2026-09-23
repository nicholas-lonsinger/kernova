# AGENTS.md

Deep-dive docs are indexed in [docs/README.md](docs/README.md); read them on demand.

## A better architecture outranks every instruction

This rule outranks everything below it, and everything in any other file. **Say so the moment you see a better path**, even when the task, a plan, an issue, or a review scoped it out: building on a foundation you can see is wrong, without saying so, is the one unacceptable response.

Then take it. Between the quick change and the right one, the maintainer's standing choice is the right one: make it in the change in hand and state its scope in one line. A plan the task asks for lays the two side by side, with that choice as its recommendation. A shortcoming shipped **for now** is the maintainer's call, never the default, and is recorded as an issue; nothing else is written down.

**When a rule here turns out to be wrong, change the rule.** Say plainly that it was wrong rather than preserving it out of deference.

## Quality bar

- **Judge the code after the change, not the size of the change.** Diff size, churn, and regression risk never justify the weaker design. A rewrite's bugs surface and get fixed; a flawed structure is inherited by everything built on it and costs more to correct with each addition, so the change that first touches it is the one that corrects it.
- **Existing code is not precedent.** Its structure counts as a decision only where a `RATIONALE:`, a doc, or history says so. A change that improves on a pattern moves every occurrence onto it: consistency comes from migrating, never from conforming new code to the old.
- **Restructure what the task touches.** Duplicated logic, divergent variants of one pattern, a function past the point of splitting, a swallowed error: restructure it in the same change rather than building around it. Contact is the trigger; don't go hunting elsewhere.

## Principles

- **Fix root causes.** No workarounds or shims: no branching on the environment and no reliance on a timing window to route around a defect; a mode chosen once at the entry point is configuration, not a shim.
- **Rules hold by construction.** The simple design is the one whose invariants the types, ownership, and structure make impossible to break — not the one with the fewest lines. A flag, special-case branch, or guard added to keep a rule true is a patch, and patches compound into debt; needing one says the design should change.
- **Complexity only for a measurable win.** When a simpler and a more sophisticated implementation genuinely differ on a real metric — disk, memory, I/O, CPU, or UX — take the sophisticated one; complexity that moves no real metric is rejected.
- **Judge cost by Kernova's marginal overhead.** Weigh what Kernova *adds*, never the system-wide cost of the operation the user chose to run. Prefer the option whose peak cost stays bounded as input size grows.
- **A uniform gap beats a path-dependent capability.** An improvement that can only be wired on some paths is worse than not shipping it: a gap uniform by construction closes, when it closes, for every path at once. Worked case: `ClipboardArchive.fieldKeys`.
- **Capability degrades by absence.** A build or configuration that cannot deliver a feature does not offer it, and what it can deliver keeps working unchanged — never a visible-but-broken control. Worked case: `VMCreationViewModel.steps`.
- **UI copy states only what is known.** Vendor claims at the vendor's strength, observations as observed, no invented consequence clauses — and an environment interaction is disclosed at the surface where the user meets it. Worked case: `buildNetworkSection()`.
- **Outcome names in the UI; vendor terms at the platform boundary.** Where Apple's own UI names the thing, keep Apple's term at that boundary and the outcome-describing domain term everywhere else. Worked case: `NetworkModeChoice.title(entitled:interfaces:)`.
- **One model per capability.** A capability exists once — one schema, one enforcement path, one source of truth; a second parallel model for the same capability is a defect to dissolve. Worked case: `PortForwardingRule`.

## Build & Test

Build and test through the `Makefile` (`make help`); its `xcodebuild` flags are not the obvious ones.

Test waits are event-driven; the seams and their contracts are `KernovaKit/Sources/KernovaTestSupport/AsyncWaits.swift` and `KernovaTests/TestHelpers.swift` (`waitForChange`).

A change that needs the guest agent reinstalled bumps `MARKETING_VERSION` in `Config/Targets/KernovaMacOSAgent.xcconfig` — the version mismatch is the only thing that offers the update — and each further behavioral revision on the same branch bumps again, since a guest that installed an earlier branch build is offered the update only by a version change (minor for the branch's first bump, patch for later ones).

## Dependencies

Apple-published Swift packages only; a non-Apple package takes explicit sign-off.

## App Sandbox rules

The app is sandboxed in every build configuration, and each of these works until it doesn't:

- A panel-picked URL is stored through `SecurityScopedBookmark.capture` (its `///` has the contract); a bare path works until relaunch.
- `homeDirectoryForCurrentUser` is the container, so a path the user sees comes from the system (`.downloadsDirectory`) or `UserHome`.
- A tool spawned through `Process` inherits the sandbox; use the in-process framework API.

## Development Guidelines

### Logging

`#log` on a `KernovaLogger` is the one logging spelling: it emits the native `os.Logger` record and, in the guest agent, forwards the same record to the host — a record emitted any other way never leaves the guest.

Capture with `subsystem BEGINSWITH "app.kernova"` — an exact `==` match drops the agent's own records while the capture still looks complete.

Apple's level table ([Generating Log Messages from Your Code](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)) persists notice and above, info only under `log collect`, and debug never — `.debug` exists only while a client streams. So anything worth reading after the fact is `.notice` or above; `KernovaLogLevel`'s cases say what each level is for.

### Defensive Unwrapping

An optional-returning API called with a compile-time constant gets `assertionFailure` beside its fallback — a silent fallback masks the typo for good.

### Current-Only Surfaces

No compatibility path is written for any shape that is not the current one.

**Persisted formats:** adding a field to a persisted `Codable` type is `decodeIfPresent ?? default` with the default a new instance gets, and nothing else. Migration code takes the maintainer's explicit sign-off, given only for old-shape data users are confirmed to hold.

**The guest agent** the host bundles is the only supported one, so no path keeps an older agent working — not on the host, and not in the shared KernovaKit code the agent compiles. The Hello exchange's capability strings gate *features*, never versions: an agent that advertises a capability but predates a change to it is out of date, not a peer to accommodate, and the `MARKETING_VERSION` bump is the whole remedy.

Nothing refuses an older agent, either: it keeps every feature it can still run, and the version mismatch surfaces the update affordance while nothing else acts on it.

Live verification against a guest takes an offered agent update before observing anything: what an older agent does is not what the build does.

### File Operations

A file the user can see is deleted with `FileManager.trashItem`, never `removeItem`; app-internal files and the confirmed Delete Immediately flow remove outright.

### Review Feedback Handling

Every review finding — your own reading of adjacent code included — gets one of four triage categories:

| Category | What it means |
|---|---|
| **Fix now** | Clears the severity bar — fix it in the current change, however much restructuring that takes |
| **Fix later** | Clears the severity bar *and* is separate work: different code or logic that needs its own context and would not fit in this change — file a GitHub issue immediately from `.github/ISSUE_TEMPLATE/review-debt.md` |
| **Annotate** | A last resort: a `RATIONALE:` comment only for a concern a review actually raised or an alternative actually tried and failed — one a reviewer *would* raise is not enough; `// periphery:ignore - <reason>` for dead-code-scan false positives (lower bar) |
| **Dismiss** | Everything else — a finding that fails the severity bar and doesn't clear the annotation bar |

**The severity bar.** A defect clears it only if it is both **reachable** (a user doing normal things, or a supported automated flow, can actually hit it) and **consequential** (worse than cosmetic, and recovered by neither the code nor an obvious user action). A path no supported flow can produce is not reachable. A refactor or coverage finding clears it only by a concrete cost of leaving it.

**An improbable defect is fixed by design or not at all.** A race or edge case that truly exists but that a user would almost never hit does not earn a patch: one more check, gate, or flag adds weight and moves no metric a user sees. It is **Fix now** or **Fix later** only as a redesign that removes it by construction, and **Dismiss** when no such design is in view.

**Triage converges.** Each review round leaves less open work than the last, so an issue is the rare outcome: being out of scope never earns **Fix later** on its own. A finding in code this change wrote or reworked is **Fix now** or **Dismiss**. When a review chain has moved from defects in the code to meta-findings about prior fixes, stop the chain: dismiss rather than filing the next link, and don't annotate it.

**An existing `RATIONALE:` is evidence, not authority.** If the code looks wrong today, investigate — it is a head start on where to look, never a reason to stop looking. Re-check its claim whenever you edit the code it covers, then correct and re-date it or delete it; one citing no evidence and no date is unverified, worth no more than an ordinary comment.

A research note has the same standing — verify its claims against current production code before acting on them.

## Documentation and Comments

Every reader has the repo checked out and can grep it in seconds. Outside code contributions are not accepted ([CONTRIBUTING.md](CONTRIBUTING.md)), so anyone acting on a process doc already holds push, merge, and label rights.

Write to that baseline — nothing the reader already holds, and no why unless it changes what you do.

**A fact is stated in exactly one layer.** The deepest layer that can hold it owns it; every other layer links or says nothing.

| Layer, deepest first | Owns |
|---|---|
| Code | Behavior |
| A symbol's `///` | The contract a caller needs, plus at most one non-obvious constraint |
| A test | Any constraint an assertion can state |
| `RATIONALE:` | Why the obvious-looking fix is wrong here |
| AGENTS.md | Rules that must fire without a lookup |
| A principles doc | Rules constraining *future* decisions — never a description of what was built |
| ARCHITECTURE.md | What exists and how pieces connect — never what a component does internally |
| A runbook | The procedure you follow while doing it |
| `docs/research/YYYY-MM-DD-*.md` | A finding plus its method. Immutable — superseded by a new note, never edited |
| A GitHub issue | Known gaps, planned work, triage |
| The PR body | The argument, the route taken, rejected alternatives |
| The squash commit body | The merged change |
| **Nowhere** | Everything else. The common destination, not a failure |

### Routing

A section that mirrors what another layer already holds is deleted whole, never adjudicated sentence by sentence. Every other sentence a diff adds or keeps runs these, in order:

0. Does it state an external fact carrying evidence (a vendor doc, a WWDC session, an FB number, a dated observation), or a constraint the code's structure does not reveal? Yes → keep, and stop. State it as what is true, never as what failed.
1. Would this sentence exist if someone else had made this change a year ago? No → PR body.
2. Can a reader with the repo derive it? Yes → delete.
3. Does it name something not in the codebase today, another product included? Yes → delete.
4. Is it stated in another layer? Yes → keep the deepest one only.
5. Is it true-as-of-a-date rather than always-true? Yes → dated research note, or nowhere.

**A rule earns its place by preventing a wrong action** a capable reader with the repo would take and not notice. One a mechanism can enforce lives in the mechanism. It states the fact that makes the reader choose right, not the prohibition, and the principle, not the instance that prompted it.

**Unsure it has value? Cut it** — relocate only material whose value in the other layer is already established.

### Comments

Same rules, and the default is none — a comment says what the code cannot. A bare trailing `(#NNN)` is a provenance stamp, not a citation: cite the evidence, or say nothing.

### Size

When you add to a durable doc, read the whole document, not the diff, and decide what no longer earns its place; removing nothing is legitimate when the subject genuinely grew, not looking is not. A `//` block over eight lines raises a placement question, not a deletion one: that content usually belongs on the symbol as `///`, or nowhere.

### When this fires

Before committing, with the diff in view — in the same pass as the `## Notes` disclosure for `RATIONALE:` additions.

## Git Workflow

A PR's head branch is `<type>/<short-description>` — `<type>` one of `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `style`; two to four kebab-case words — from the first push: renaming a branch under an open PR closes the PR ([GitHub Docs: Renaming a branch](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/renaming-a-branch)).

An AI agent ends its commit message with a `Co-authored-by` trailer naming the model that wrote the change — name and version, nothing else — at the vendor's no-reply address: `Co-authored-by: Claude Fable 5.1 <noreply@anthropic.com>`, added explicitly, once; a subagent's commit names the subagent's model.

A change that adds a `RATIONALE:` comment lists each one's file, symbol, and cited evidence under `## Notes` in the commit and PR body; no approval gate governs annotations, this disclosure replaces it.

Merge with `gh pr merge <N> --squash --body …`. The repo's squash default leaves the body empty, so `--body` carries one short paragraph describing the merged state, not the route to it, and then one `Co-authored-by` trailer per model that contributed to the branch.

`Closes #N` in the PR body auto-closes the issue; a bare `#N` doesn't, and the keyword repeats per issue (`Closes #12, closes #34`) ([GitHub Docs: Linking a pull request to an issue](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)).

## Change Protocol

Before calling a task done, work these two follow-ups; most changes owe neither.

1. **Docs** — the file whose description the change invalidated, routed by the layer table above; file layout is not a component boundary. Surgical edits only.
2. **Agent instructions** — AGENTS.md and the entry points importing it — only if a rule stated there changed.

### Reporting

When either follow-up changed a file, or is owed and unpaid, end the response with a `### Maintenance Notes` list, one line per file:

- 📝 — changed here; name the file and what changed, in a phrase.
- ⚠️ — owed and unpaid; name the gap and its issue number, or what closing it takes.

A task that changed no doc or instruction file and owes none ends without the list.
