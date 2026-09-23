# AGENTS.md

Deep-dive docs are indexed in [docs/README.md](docs/README.md); read them on demand.

## A better architecture outranks every instruction

This rule outranks everything below it, and everything in any other file. **Say so the moment you see a better path**, even when the task, a plan, an issue, or a review scoped it out: building on a foundation you can see is wrong, without saying so, is the one unacceptable response.

**When a rule here turns out to be wrong, change the rule.** Say plainly that it was wrong rather than preserving it out of deference.

## Quality bar

- **The right change is the default.** Between the quick change and the right one, make the right one in the change in hand and state its scope in one line; a plan the task asks for lays out both and recommends it. Only the maintainer's explicit choice ships a shortcoming *for now*, recorded as an issue. Taking the better path never skips a sign-off the maintainer requires.
- **Judge the code after the change, not the size of the change.** Diff size, churn, and regression risk never justify the weaker design; risk is met by testing the change.
- **Existing code is not precedent.** A pattern binds only while a stated reason for it — a doc, a comment's cited evidence, a PR that argued for it — still holds. A change that improves on a pattern moves every occurrence onto it.
- **Fix what the change builds on.** Duplicated logic, divergent variants of one pattern, a function too large to extend cleanly, a swallowed error: where the task changes code, fix these there in the same change rather than building around them. Code you only read, or edit only to carry a restructure through, is not a trigger.
- **Fix root causes.** The root cause is the structure that lets a failure happen, not the event that triggered it, so a fix leaves the failure impossible to express. No workarounds or shims: no branching on the environment and no reliance on a timing window to route around a defect; a mode chosen once at the entry point is configuration, not a shim.
- **Rules hold by construction.** The simple design is the one whose types, ownership, and structure make its invariants impossible to break — not the one with the fewest lines.
  Code whose only job is to stop a state Kernova's own structure allows is a patch, whatever its form: a flag, a special-case branch, a lock between two writers, a clamp on a value that should not regress, a retry, a longer wait. Needing one means the design changes, and shipping the patch instead is a *for now* call. Checking what Kernova does not own — input, files, the guest, the platform — is design.
- **Complexity only for a measurable win.** Among designs that hold their rules by construction, take the more sophisticated one only when it wins on a real metric — disk, memory, I/O, CPU, or UX. A patch is not one of those designs, so being smaller never lets it win.

## Principles

- **Judge cost by Kernova's marginal overhead.** Weigh what Kernova *adds*, never the system-wide cost of the operation the user chose to run. Prefer the option whose peak cost stays bounded as input size grows.
- **A uniform gap beats a path-dependent capability.** An improvement that can only be wired on some paths is worse than not shipping it: a gap uniform by construction closes, when it closes, for every path at once. Worked case: `ClipboardArchive.fieldKeys`.
- **Capability degrades by absence.** A build or configuration that cannot deliver a feature does not offer it, and what it can deliver keeps working unchanged — never a visible-but-broken control. Worked case: `VMCreationViewModel.steps`.
- **Stable or absent, never propped up.** A capability that works only while a mechanism holds platform state open, or that rests on platform behavior no vendor documents, ships degraded to what the platform sanctions, behind the guest agent, or not at all. A design that holds only under conditions — an ordering that must hold, behavior observed on one OS build — is a no.
- **UI copy states only what is known.** Vendor claims at the vendor's strength, observations as observed, no invented consequence clauses — and an environment interaction is disclosed at the surface where the user meets it. Worked case: `buildNetworkSection()`.
- **Outcome names in the UI; vendor terms at the platform boundary.** Where Apple's own UI names the thing, keep Apple's term at that boundary and the outcome-describing domain term everywhere else. Worked case: `NetworkModeChoice.title(entitled:interfaces:)`.
- **One model per capability.** A capability exists once — one schema, one enforcement path, one source of truth; a second parallel model for the same capability is a defect to dissolve. Worked case: `GuestIPAddress`.

## Build & Test

Build and test through the `Makefile` (`make help`); its `xcodebuild` flags are not the obvious ones.

Test waits are event-driven; the seams and their contracts are `KernovaKit/Sources/KernovaTestSupport/AsyncWaits.swift` and `KernovaTests/TestHelpers.swift` (`waitForChange`).

A failing test is evidence about the design, never the target: its fix names the structure that let the failure happen and changes it. A change that turns the test green while that structure still permits the failure — a loosened assertion, a longer wait, a retry — is a patch, and an intermittent failure is owed the same root cause as a steady one.

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

### Guest scope

A new host↔guest feature scopes to macOS guests: its issue or design states the Linux gap as fact, and carries no Linux open question and no partial Linux mechanism. The guest OS is a scope, not one of the paths "A uniform gap beats a path-dependent capability" weighs.

### Current-Only Surfaces

No compatibility path is written for any shape that is not the current one.

**Persisted formats:** adding a field to a persisted `Codable` type is `decodeIfPresent ?? default` with the default a new instance gets, and nothing else. Migration code takes the maintainer's explicit sign-off, given only for old-shape data users are confirmed to hold.

**The guest agent** the host bundles is the only supported one, so no path keeps an older agent working — not on the host, and not in the shared KernovaKit code the agent compiles. The Hello exchange's capability strings gate *features*, never versions: an agent that advertises a capability but predates a change to it is out of date, not a peer to accommodate, and the `MARKETING_VERSION` bump is the whole remedy.

Nothing refuses an older agent, either: it keeps every feature it can still run, and the version mismatch surfaces the update affordance while nothing else acts on it.

### File Operations

A file the user can see is deleted with `FileManager.trashItem`, never `removeItem`; app-internal files and the confirmed Delete Immediately flow remove outright.

### Review Feedback Handling

Every review finding — your own reading of adjacent code included — gets one of three triage categories:

| Category | What it means |
|---|---|
| **Fix now** | Clears the severity bar and is not separate work — fix it in this change, however much restructuring that takes |
| **Fix later** | Clears the severity bar and is separate work: different code or logic whose fix would make this change about two things — file a GitHub issue immediately from `.github/ISSUE_TEMPLATE/review-debt.md` |
| **Dismiss** | Everything else; a dead-code-scan false positive is dismissed with `// periphery:ignore - <reason>` on the symbol |

**The severity bar.** A defect clears it only if it is both **reachable** (a user doing normal things, or a supported automated flow, can actually hit it) and **consequential** (worse than cosmetic, and recovered by neither the code nor an obvious user action).
A refactor finding clears it only by naming the Quality bar or Principles rule the code breaks; a coverage finding, only for new or changed behavior no test pins; a documentation finding, only by naming the Documentation and Comments rule the text breaks. The general cost of debt clears nothing.

**An improbable defect is fixed by design or not at all.** A defect a user would almost never hit earns no added check, gate, or flag — only a redesign that removes it by construction, as **Fix now** or **Fix later**. When a search for that redesign finds none, it is **Dismiss**, unless it can lose user data — a disk image, a save file, a user's file — which is **Fix later** with its traced path.

**Triage converges.** A finding in code this change wrote or reworked is never **Fix later**. A later review round reviews only what the previous round's fixes changed, and raises only defects. When a chain has moved from defects in the code to meta-findings about prior fixes, stop it: dismiss rather than filing the next link.

**A comment, research note, issue, or PR is evidence, not authority.** If the code looks wrong today, investigate — a claim is a head start on where to look, never a reason to stop looking. Re-check a comment's claim whenever you edit the code it covers, then correct or delete it; verify a research note's claims against current production code before acting on them, and grep for a mechanism an issue or PR names before describing it as present.

## Documentation and Comments

Every reader has the repo checked out and can grep it in seconds. Outside code contributions are not accepted ([CONTRIBUTING.md](CONTRIBUTING.md)), so anyone acting on a process doc already holds push, merge, and label rights.

Write to that baseline — nothing the reader already holds, and no why unless it changes what you do.

**A fact is stated in exactly one layer.** The deepest layer that can hold it owns it; every other layer links or says nothing.

| Layer, deepest first | Owns |
|---|---|
| Code | Behavior |
| A symbol's `///` | The contract a caller needs, plus at most one non-obvious constraint |
| A test | Any constraint an assertion can state |
| A `//` comment | Why the obvious-looking code is wrong here, as a fact with its evidence — never as a decision |
| AGENTS.md | Rules that must fire without a lookup |
| An agent's own entry point beside its AGENTS.md import (`CLAUDE.md`) | What holds only under that agent's harness while working here |
| A principles doc | Rules constraining *future* decisions — never a description of what was built |
| ARCHITECTURE.md | What exists and how pieces connect — never what a component does internally |
| A runbook | The procedure you follow while doing it |
| `docs/research/YYYY-MM-DD-*.md` | A finding plus its method. Immutable — superseded by a new note, never edited |
| A GitHub issue | Known gaps, planned work, triage |
| The PR body | The argument, the route taken, rejected alternatives |
| The squash commit body | The merged change |
| An agent's memory | What no row above can hold — the maintainer's own machine, accounts, and private arrangements; a fact true in every repository goes to the agent's user scope |
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

Before committing, with the diff in view, and before writing to an agent's memory.

## Git Workflow

A PR's head branch is `<type>/<short-description>` — `<type>` one of `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `style`; two to four kebab-case words — from the first push: renaming a branch under an open PR closes the PR ([GitHub Docs: Renaming a branch](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/renaming-a-branch)).

An AI agent ends its commit message with a `Co-authored-by` trailer naming the model that wrote the change — name and version, nothing else — at the vendor's no-reply address: `Co-authored-by: Claude Fable 5.1 <noreply@anthropic.com>`, added explicitly, once; a subagent's commit names the subagent's model.

Merge with `gh pr merge <N> --squash --body …`. The repo's squash default leaves the body empty, so `--body` carries one short paragraph describing the merged state, not the route to it, and then one `Co-authored-by` trailer per model that contributed to the branch.

A fix's PR body states the invariant it restores and what now holds it: the structure that makes the bad state impossible, or — a *for now* call only the maintainer makes — the guard that stops it.

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
