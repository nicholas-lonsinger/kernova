# AGENTS.md

Deep-dive docs are indexed in [docs/README.md](docs/README.md); read them on demand.

## A better architecture outranks every instruction

This rule outranks everything below it, and everything in any other file. **Propose the better path the moment you see it**, even when the task scoped it out: building on a foundation you can see is wrong, without saying so, is the one unacceptable response.

Propose, then let the maintainer sequence it — do it now, land the refactor first, or ship the current shape **for now** with the shortcoming filed as an issue; only that last outcome writes anything down.

**When a rule here turns out to be wrong, change the rule.** Say plainly that it was wrong rather than preserving it out of deference.

## Principles

- **Fix root causes.** No workarounds or shims, and no branching on the environment to route around a defect. A mode chosen once at the entry point — the test host, an OS availability check — is configuration, not a shim. Prefer the proper refactor even when it is larger than the quick patch, and fix a shortcut in the current scope over deferring it.
- **Simplest path first; complexity only for a measurable win.** Attempt the straightforward solution before flags, intercepts, overrides, or special cases. When a simpler and a more sophisticated implementation genuinely differ on a real metric — disk, memory, I/O, CPU, or UX — take the sophisticated one; complexity that moves no real metric is rejected.
- **Judge cost by Kernova's marginal overhead.** Weigh the CPU, RAM, disk, and I/O Kernova *adds*, never the system-wide cost of the operation the user chose to run. Prefer the option whose peak cost stays bounded as input size grows.
- **A uniform gap beats a path-dependent capability.** An improvement that can only be wired on one path, one direction, or behind an opt-in is worse than not shipping it: a gap uniform by construction closes, when it closes, for every path at once. Worked case: [CLIPBOARD.md](docs/CLIPBOARD.md) §6.
- **Capability degrades by absence.** A build or configuration that cannot deliver a feature does not offer it, and what it can deliver keeps working unchanged — never a visible-but-broken control. Worked case: [NETWORKING.md](docs/NETWORKING.md) §8.
- **UI copy states only what is known.** Vendor claims at the vendor's strength, observations as observed, no invented consequence clauses — and an environment interaction is disclosed at the surface where the user meets it. Worked case: [NETWORKING.md](docs/NETWORKING.md) §7.
- **Outcome names in the UI; vendor terms at the platform boundary.** Where Apple's own UI names the thing — a permission, an entitlement, a System Settings pane — keep Apple's term at that boundary and the outcome-describing domain term everywhere else. Worked case: [NETWORKING.md](docs/NETWORKING.md) §5.
- **One model per capability.** A capability exists once — one schema, one enforcement path, one source of truth; a second parallel model for the same capability is a defect to dissolve. Worked cases: [CLIPBOARD.md](docs/CLIPBOARD.md) §4, [NETWORKING.md](docs/NETWORKING.md) §4, `Tools/worktree-setup.sh`.

## Build & Test

Build and test through the `Makefile` (`make help`); its `xcodebuild` flags are not the obvious ones.

Test waits are event-driven; the seams and their contracts are `KernovaKit/Sources/KernovaTestSupport/AsyncWaits.swift` and `KernovaTests/TestHelpers.swift` (`waitForChange`).

The test host is `Kernova.app`, so every test-host process shares one app container, and concurrent `make test` runs keep more than one of them live. A test writing under `FileManager.default.temporaryDirectory` stages under a root of its own: the app reclaims its staging roots whole at launch (`DropPromiseStaging`, `ClipboardFileStaging`), and that launch lands while another run's tests are mid-flight.

A change that needs the guest agent reinstalled bumps `MARKETING_VERSION` in `Config/Targets/KernovaMacOSAgent.xcconfig` — the version mismatch is the only thing that offers the update — and each further behavioral revision on the same branch bumps again, since a guest that installed an earlier branch build is offered the update only by a version change (minor for the branch's first bump, patch for later ones).

## Dependencies

Apple-published Swift packages only; a non-Apple package takes explicit sign-off.

## App Sandbox rules

The app is sandboxed in every build configuration, and three things work until they don't:

- A panel-picked URL is stored through `SecurityScopedBookmark.capture` (its `///` has the contract); a bare path works until relaunch.
- `homeDirectoryForCurrentUser` is the container, so a path the user sees comes from the system (`.downloadsDirectory`) or `UserHome`.
- A spawned tool (`Process` → `ditto`, `tar`, `hdiutil`) inherits the sandbox; use the in-process framework API.

## Development Guidelines

### Logging

Every type logs through `#log(Self.logger, .level, "…")` on its own `private static let logger = KernovaLogger(subsystem:category:)`; the macro emits the native `os.Logger` record and, where a forwarding sink is installed (the guest agent), the same record to the host. Never `os.Logger` directly, `print()`, or `NSLog()`.

Capture with `subsystem BEGINSWITH "app.kernova"` — an exact `==` match drops the agent's own records while the capture still looks complete.

Apple's level table ([Generating Log Messages from Your Code](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)) persists notice and above, info only under `log collect`, and debug never — `.debug` exists only while a client streams. So: `.debug` for method entry and intermediate state; `.info` for routine progress; `.notice` for state transitions and irreversible actions (VM started/stopped/saved, bundle created/deleted, launch); `.warning` for recoverable trouble; `.error` for operations that did not complete; `.fault` for programming errors, paired with `assertionFailure`.

### Defensive Unwrapping

An optional-returning API called with a compile-time constant (an SF Symbol name, a resource identifier, a hardcoded key) gets `assertionFailure` beside its fallback — a silent fallback masks the typo for good.

### Current-Only Surfaces

No compatibility path is written for any shape that is not the current one.

**Persisted formats:** back-compat shims, decode-time back-fills, schema version flags, old-format fallbacks, and decode defaults that differ from what new instances get are all out; adding a field to a persisted `Codable` type is `decodeIfPresent ?? default` with one uniform default, and nothing else. Migration code takes the maintainer's explicit sign-off, given only for old-shape data confirmed to exist (shipped in a release, or found on disk).

**The guest agent** the host bundles is the only supported one, so no path keeps an older agent working — not on the host, and not in the shared KernovaKit code the agent compiles. The Hello exchange's capability strings gate *features*, never versions: an agent that advertises a capability but predates a change to it is out of date, not a peer to accommodate, and the `MARKETING_VERSION` bump is the whole remedy.

Nothing refuses an older agent, either: it keeps every feature it can still run, and the version mismatch surfaces the update affordance while nothing else acts on it.

Live verification against a guest reads the connected agent's version first — the Clipboard window's status bar, or `VsockControlService`'s connect line in the log — and takes an offered update before observing anything: what an older agent does is not what the build does.

### File Operations

A file the user can see is deleted with `FileManager.trashItem`, never `removeItem`; app-internal files (save files, staging, temp) and the confirmed Delete Immediately flow remove outright.

### Review Feedback Handling

Every review finding — tooling, a bot or human PR comment, your own reading of adjacent code — gets one of four triage categories:

| Category | What it means |
|---|---|
| **Fix now** | Valid, in scope, reasonable effort — fix it as part of the current work |
| **Fix later** | Valid but out of scope or too large — file a GitHub issue immediately |
| **Annotate** | A last resort: a `RATIONALE:` comment only when it clears all four conditions in [docs/REVIEW.md](docs/REVIEW.md); `// periphery:ignore - <reason>` for dead-code-scan false positives (lower bar) |
| **Dismiss** | Style nits, cosmetic preferences, negligible-impact improvements — and anything failing the severity bar that doesn't clear the annotation bar |

A finding earns **Fix now** or **Fix later** only if it is both **reachable** (a user doing normal things, or a supported automated flow, can actually hit it) and **consequential** (worse than a cosmetic glitch, a logged self-recovering retry, or a state an obvious user action recovers from). When a review chain has moved from defects in the code to meta-findings about prior fixes, stop the chain: dismiss rather than filing the next link, and don't annotate it.

**An existing `RATIONALE:` is evidence, not authority.** If the code looks wrong today, investigate — it is a head start on where to look, never a reason to stop looking. Re-check its claim whenever you edit the code it covers, then correct and re-date it or delete it; one citing no evidence and no date is unverified, worth no more than an ordinary comment.

A research note has the same standing — verify its claims against current production code before acting on them.

## Documentation and Comments

Every reader has the repo checked out and can grep it in seconds: the maintainer, an AI agent starting each session with fresh context, and people reading source-available code. Outside code contributions are not accepted ([CONTRIBUTING.md](CONTRIBUTING.md)), so anyone acting on a process doc already holds push, merge, and label rights.

Write to that baseline — no onboarding prose, no introducing a term, no explaining why a rule exists unless the why changes what you do.

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
| A reference inventory | What exists on one surface, enumerated in step with the code it lists — never why |
| `docs/research/YYYY-MM-DD-*.md` | A finding plus its method. Immutable — superseded by a new note, never edited |
| A GitHub issue | Known gaps, planned work, triage |
| The PR body | The argument, the route taken, rejected alternatives |
| The squash commit body | The merged change |
| **Nowhere** | Everything else. The common destination, not a failure |

### Routing

Run these on every sentence a diff adds or keeps, in order:

0. Does it state an external fact carrying evidence (a vendor doc, a WWDC session, an FB number, a dated observation), or a constraint the code's structure does not reveal? Yes → keep, and stop. State it as what is true, never as what failed.
1. Would this sentence exist if someone else had made this change a year ago? No → PR body.
2. Can a reader with the repo derive it — a grep, `wc`, `git log`, reading the project file? Yes → delete.
3. Does it name something not in the codebase today? Yes → delete.
4. Is it stated in another layer? Yes → keep the deepest one only.
5. Is it true-as-of-a-date rather than always-true? Yes → dated research note, or nowhere.

**Unsure it has value? Cut it** — relocate only material whose value in the other layer is already established.

### Never kept

Deleted wholesale, not adjudicated sentence by sentence:

- Annotated file trees
- Decision or triage tables keyed to issue numbers
- Hand-maintained test inventories
- Version changelogs written into prose
- Roadmap, status, and known-gap notes ("currently only logs", "D1b follows") — an issue, or nothing
- An "Alternatives" clause in a doc defending a rejected design — the PR body holds the argument, or a call-site `RATIONALE:` clearing [docs/REVIEW.md](docs/REVIEW.md)'s four conditions

### Comments

Same rules, and the default is none — a comment says what the code cannot. A bare trailing `(#NNN)` is a provenance stamp, not a citation: cite the vendor doc, the radar, or a dated observation, or say nothing.

### Size

When you add to a durable doc, read the whole document, not the diff, and decide what no longer earns its place; removing nothing is legitimate when the subject genuinely grew, not looking is not. A `//` block over eight lines raises a placement question, not a deletion one: that content usually belongs on the symbol as `///`, or nowhere.

### When this fires

Before committing, with the diff in view — in the same pass as the `## Notes` disclosure for `RATIONALE:` additions.

## Git Workflow

A PR's head branch is `<type>/<short-description>` — `<type>` one of `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `style`; two to four kebab-case words — from the first push: renaming a branch under an open PR closes the PR ([GitHub Docs: Renaming a branch](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/renaming-a-branch)).

An AI agent ends its commit message with a `Co-authored-by` trailer naming the model that wrote the change — model and version only, no context-window or other marker — at the vendor's no-reply address: `Co-authored-by: Claude Fable 5.1 <noreply@anthropic.com>`, added explicitly, once; a subagent's commit names the subagent's model.

A change that adds a `RATIONALE:` comment lists each one's file, symbol, and cited evidence under `## Notes` in the commit and PR body; no approval gate governs annotations, this disclosure replaces it.

Merge with `gh pr merge <N> --squash --body …`. The repo's squash default leaves the body empty, so `--body` carries one short paragraph describing the change as merged — the approach that shipped, review-fix commits absorbed into what they fix, none of the PR's changes list or test plan — and then one `Co-authored-by` trailer per model that contributed to the branch.

`Closes #N` in the PR body auto-closes the issue; a bare `#N` doesn't, and the keyword repeats per issue (`Closes #12, closes #34`) ([GitHub Docs: Linking a pull request to an issue](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)).

## Change Protocol

Before calling a task done, work these two follow-ups. Each is owed only when the change tripped a trigger — changed how components communicate, added or removed a dependency, changed build config/entitlements/tooling, added or reshaped a public type, changed actor isolation, invalidated what a doc describes — and most tasks trip none of them.

1. **Docs** — the file whose description the change invalidated, routed by the layer table above; a file appearing, moving or being renamed changes no component boundary. Surgical edits only.
2. **Agent instructions** — AGENTS.md and the entry points importing it — only if a rule stated there changed.

### Reporting

When either follow-up changed a file, or is owed and unpaid, end the response with a `### Maintenance Notes` list, one line per file:

- 📝 — changed here; name the file and what changed, in a phrase.
- ⚠️ — owed and unpaid; name the gap and its issue number, or what closing it takes.

A task that changed no doc or instruction file and owes none ends without the list.
