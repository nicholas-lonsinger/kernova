# AGENTS.md

The tool-neutral operating guide for this repository. Deep-dive docs are indexed in [docs/README.md](docs/README.md); read them on demand.

> Design philosophy and UI guidelines: [docs/SPEC.md](docs/SPEC.md).
>
> Clipboard subsystem principles — authoritative for host↔guest copy/paste work: [docs/CLIPBOARD.md](docs/CLIPBOARD.md).

## Build & Test

Xcode project, not SwiftPM. From the terminal go through the `Makefile` (`make help` lists every target) — never hand-write an `xcodebuild` invocation; the flags are not the obvious ones. Fresh-clone setup: [README](README.md#development-setup); machinery: [docs/BUILD.md](docs/BUILD.md).

The app is Apple Silicon-only (`ARCHS = arm64` project-wide), so `#if arch(arm64)` guards are unnecessary.

A new top-level target needing a dynamic build number calls `Tools/set-build-number.sh <app|agent>` from a `Set Build Number from Git` build phase — never patch the built `Info.plist`.

Any change requiring a guest-agent reinstall bumps its `MARKETING_VERSION` — every occurrence together ([docs/BUILD.md](docs/BUILD.md)).

## Architecture

> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has what exists and how the pieces connect — consult it before structural changes.

Kernova is a **pure-AppKit** app managing macOS and Linux guests via `Virtualization.framework`.

**Concurrency model:** Swift 6 strict concurrency. Everything touching `VZVirtualMachine`, including every service that talks to VZ, is `@MainActor`; stateless services are `Sendable` structs. VZ delegate callbacks bridge back with `nonisolated(unsafe)` plus `MainActor.assumeIsolated`.

**No third-party dependencies.** Apple-published Swift Packages (e.g. `apple/swift-protobuf`) are acceptable when they pull their weight; non-Apple packages require explicit sign-off.

## App Sandbox rules

The app **runs under the App Sandbox in every build configuration** and targets the **Mac App Store** — write code that lives within both ([docs/SANDBOX.md](docs/SANDBOX.md)):

- **User-picked files persist their grant as an app-scoped security bookmark** stored next to the raw path (`SecurityScopedBookmark.capture` at the pick site), resolved through the RAII `ScopedAccess`. A dead bookmark falls through to the raw path and re-picking mints a fresh one — bookmarks never need repair or migration handling.
- **App-internal state belongs in the container** — `.applicationSupportDirectory` and `FileManager.temporaryDirectory` both resolve correctly there. Never build paths off `homeDirectoryForCurrentUser` expecting the *real* home; it is the container home, so ask the system for the folder (e.g. `.downloadsDirectory`).
- **Prefer in-process Apple framework APIs over shelling out** to command-line tools (`Process` / `NSTask` → `/usr/bin/ditto`, `unzip`, `tar`, …), which a sandboxed app cannot usefully spawn — and over entitlements unavailable to MAS apps.

## Development Guidelines

### Unit Tests

New and changed behavior ships with tests, following `KernovaTests/`:

- Swift Testing (`@Suite`, `@Test`, `#expect`) — never XCTest; protocol-based mocks in `KernovaTests/Mocks/`
- Test models, services, and view models — UI views need none
- Cover happy *and* error paths, injecting failures via a per-method `<method>Error` property
- Reuse shared helpers and factories (`makeInstance()`), don't duplicate setup
- Run the full test suite before committing

**Async waits in tests must be event-driven, not poll loops.** Pick the seam per the table in [docs/TESTING.md](docs/TESTING.md), which also owns the injected-timeout and test-seam rules. Polling is acceptable only for genuinely signal-less predicates, and needs a one-line `RATIONALE:` naming the category.

### Logging

Every type that logs declares its own `private static let logger = Logger(subsystem: "app.kernova", category: "ComponentName")`. Never use `print()`, `NSLog()`, or file-based logging. Subsystems are per-target:

| Subsystem | Who logs there |
|-----------|----------------|
| `app.kernova` | The host app, the helpers it embeds, and all `KernovaKit` code, including KernovaKit types running *inside* the agent process |
| `app.kernova.macosagent` | The guest agent's own components |
| `app.kernova.guest` | Host-side re-logging of forwarded guest records (category = VM name) |

Capture with `subsystem BEGINSWITH "app.kernova"`: an exact `== "app.kernova"` match silently drops the agent's records, and because KernovaKit code inside that process still matches, the truncated capture *looks* complete.

Only `.notice` and above persist to disk; `.debug` reaches no store at all and exists only while a client streams (`log stream`, Console.app). Use `.debug` for method entry and intermediate state; `.info` for routine progress; `.notice` for state transitions and irreversible actions (VM started/stopped/saved, bundle created/deleted, launch); `.warning` for recoverable trouble (missing files, fallbacks, degraded operation); `.error` for operations that did not complete; `.fault` for programming errors, paired with `assertionFailure`.

### Defensive Unwrapping

An optional-returning API called with compile-time-known input (SF Symbol names, resource identifiers, hardcoded keys) gets `assertionFailure` and a graceful fallback:

```swift
guard let value = knownGoodAPI("compile-time-constant") else {
    logger.fault("Descriptive message '\(context, privacy: .public)'")
    assertionFailure("Descriptive message: \(context)")
    return fallbackValue
}
```

Never force-unwrap (`!`) — it crashes end users — and never return a fallback silently, without `assertionFailure`; that masks bugs during development.

### Persisted Data

Persisted formats are current-only — no migration code. Back-compat shims, decode-time back-fills, schema version flags, old-format fallbacks, and decode defaults that differ from what new instances get are all out. Adding a field to a persisted `Codable` type is `decodeIfPresent ?? default` with one uniform default, and nothing else. Migration code takes the maintainer's explicit sign-off, given only for old-shape data confirmed to exist (shipped in a release, or found on disk).

### File Operations

Prefer `trash` over `rm` when deleting files. A user-confirmed permanent-delete flow ("Delete Immediately") is the exception and removes outright.

### Review Feedback Handling

Every review finding — tooling, a bot or human PR comment, your own reading of adjacent code — gets one of four triage categories:

| Category | What it means |
|---|---|
| **Fix now** | Valid, in scope, reasonable effort — fix it as part of the current work |
| **Fix later** | Valid but out of scope or too large — file a GitHub issue immediately |
| **Annotate** | A **last resort**: add a `RATIONALE:` comment only when it clears all four conditions in [docs/REVIEW.md](docs/REVIEW.md), disclosed in the commit/PR summary. Or `// periphery:ignore - <reason>` for dead-code-scan false positives (lower bar; same file) |
| **Dismiss** | Style nits, cosmetic preferences, negligible-impact improvements — and anything failing the severity bar that doesn't clear the annotation bar |

**The severity bar — Dismiss and Annotate are real options.**

- A finding earns **Fix now** or **Fix later** only if it is both **reachable** (a user doing normal things, or a supported automated flow, can actually hit it) and **consequential** (worse than a cosmetic glitch, a logged self-recovering retry, or a state an obvious user action recovers from).
- Hypothetical future code, adversarial scheduling no real flow produces, degenerate inputs, and pre-existing behavior merely surfaced by an unrelated diff default to **Dismiss**. Escalating to **Annotate** takes a pattern *actually* re-flagged across reviews, not one that might be.
- When a review chain has moved from defects in the code to meta-findings about prior fixes, stop the chain: dismiss rather than filing the next link, and resist annotating it — a comment defending the previous fix is the same dead end.

Read [docs/REVIEW.md](docs/REVIEW.md) before filing an issue or writing an annotation — it owns the severity-bar examples, issue template, labels, hygiene rules, and formats.

**Reading an existing `RATIONALE:` — it is evidence, not authority.** It is a claim *as of when it was written*, with the standing of an old issue: accurate then, not authoritative now. If the code looks wrong *today*, investigate — it is a head start on where to look, never a reason to stop looking.

Re-check its claim whenever you edit the code it covers, then correct and re-date it or delete it. Treat one citing no evidence and no date as **unverified**, worth no more than an ordinary comment. Deleting one that no longer holds is maintenance, not churn.

## Documentation and Comments

Every reader has the repo checked out and can grep it in seconds: the maintainer, an AI agent starting each session with fresh context, and people reading source-available code. Outside code contributions are not accepted ([CONTRIBUTING.md](CONTRIBUTING.md)), so anyone acting on a process doc already holds push, merge, and label rights.

Write to that baseline — no onboarding prose, no introducing a term, no explaining why a rule exists unless the why changes what you do. Every doc opens with a read-trigger, matching [docs/README.md](docs/README.md)'s "Read it when" column, and names its reader; naming the reader is what lets [docs/RELEASING.md](docs/RELEASING.md) omit everything that reader already knows.

**A fact is stated in exactly one layer.** The deepest layer that can hold it owns it; every other layer links or says nothing. Repeating a fact across layers is duplication that drifts, not thoroughness.

| Layer, deepest first | Owns |
|---|---|
| Code | Behavior |
| A symbol's `///` | The contract a caller needs, plus at most one non-obvious constraint |
| A test | Any constraint an assertion can state |
| `RATIONALE:` | Why the obvious-looking fix is wrong here |
| AGENTS.md | Rules that must fire without a lookup |
| A principles doc (SPEC, CLIPBOARD) | Rules constraining *future* decisions — never a description of what was built |
| ARCHITECTURE.md | What exists and how pieces connect — never what a component does internally |
| A runbook (BUILD, RELEASING, TESTING, REVIEW) | The procedure you follow while doing it |
| `docs/research/YYYY-MM-DD-*.md` | A finding plus its method. Immutable — superseded by a new note, never edited |
| A GitHub issue | Known gaps, planned work, triage |
| The PR body | The argument, the route taken, rejected alternatives |
| The squash commit body | The merged change |
| **Nowhere** | Everything else. The common destination, not a failure |

### Routing

Run these on every sentence a diff adds or keeps, in order:

0. Does it state an external fact carrying evidence (a vendor doc, a WWDC session, an FB number, a dated observation), or a constraint the code's structure does not reveal? Yes → keep, and stop. Such a fact usually names something outside the tree, so this gate precedes test 3. State it as what is true, never as what failed — a negative claim has no expiry and nothing triggers a re-test, so it outlives the limitation it describes.
1. Would this sentence exist if someone else had made this change a year ago? No → PR body.
2. Can a reader with the repo derive it — a grep, `wc`, `git log`, reading the project file? Yes → delete. A derivable value written down is a second source of truth that can disagree with the first, and a reader cannot tell which is current without deriving it anyway.
3. Does it name something not in the codebase today? Yes → delete.
4. Is it stated in another layer? Yes → keep the deepest one only.
5. Is it true-as-of-a-date rather than always-true? Yes → dated research note, or nowhere.

**If you are unsure it has value, cut it.** Not "move it somewhere" — cut. Relocation is only for material whose value in the other layer is already established.

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

When you add to a durable doc, read the whole document, not the diff, and decide what no longer earns its place. Growth is invisible at diff altitude: a 5,267-character line was once edited to 5,577 inside a `+1 -1` diff.

Removing nothing is legitimate when the subject genuinely grew; not looking is not. Keep a sentence carrying external evidence, or a constraint the code does not reveal, whatever it costs in length — test 0 outranks size, always.

A `//` block over eight lines raises a placement question, not a deletion one: that content usually belongs on the symbol as `///`, or nowhere. The one hard cap is no doc line over 80 words, because an over-long line is unreviewable at any content quality and the fix is always to break the line.

### When this fires

Before committing, with the diff in view — in the same pass as the `## Notes` disclosure for `RATIONALE:` additions. Route then, not while drafting, when the change is all you see.

## Git Workflow

### Branch Naming

Remote/PR branches use a clean `<type>/<short-description>` name — `<type>` matches the commit type prefixes below, description 2-4 kebab-case words (`fix/display-sizing-on-switch`). A PR's head branch must carry this name from the first push: renaming a branch on GitHub *after* a PR exists closes the PR instead of retargeting.

### Commit Messages

The subject line, type prefix, and trailer below apply to **every** commit; the sectioned body is for branch commits — a squash merge's body differs ([Merging Pull Requests](#merging-pull-requests)).

```
<type>: <concise subject line>

## Summary
- <what capability was added/fixed/changed, and why>

## Changes
- <files, types, or components modified>

## Test plan
- [ ] <verification step>
```

`## Notes` is optional for caveats and follow-ups, and **required when the change adds a `RATIONALE:` comment** — list each one's file, symbol, and cited evidence. No approval gate governs annotations; this disclosure replaces it, so a silent addition is the one thing not allowed.

#### Type prefixes

| Prefix     | Usage                     |
|------------|---------------------------|
| `feat`     | New feature or capability |
| `fix`      | Bug fix                   |
| `refactor` | No behavior change        |
| `docs`     | Documentation only        |
| `test`     | Tests only                |
| `chore`    | Build, CI, tooling, deps  |
| `style`    | Formatting or cosmetic    |

#### Scoping the message

A commit message reflects the full scope of the change, not just the last operation — review the task context and the staged diff first. Lead with the primary purpose; secondary details belong in the body.

An AI agent ends its commit message with a `Co-authored-by: Claude <noreply@anthropic.com>` trailer — no model name, its own identity if it isn't Claude. It is **not** automatic: add it explicitly (`git commit --trailer "…"`), exactly once, never also in the body. A squash merge doesn't inherit it from the branch — it comes from the `--body` at merge time.

### Merging Pull Requests

Always squash-merge. `--subject` is the PR title plus the PR number in parentheses: `"fix: Title (#11)"`.

**Always pass `--body`, and never pass it empty.** `gh` forwards it verbatim: the squash commit gets no `Co-authored-by` trailer from the branch, and omitting `--body` falls back to the branch's commit messages concatenated. Write it yourself:

```
gh pr merge <N> --squash \
  --subject "<type>: <PR title> (#<N>)" \
  --body "$(cat <<'EOF'
<one short paragraph describing the change as merged>

Co-authored-by: Claude <noreply@anthropic.com>
EOF
)"
```

**Describe the merged state, not the route to it.** Write from the final diff: only the approach that shipped, review-fix commits absorbed into what they fix. Keep it to the PR's `## Summary` — `## Changes` and `## Test plan` belong on the PR, not in `git log`.

**Do not use `--delete-branch`.** Remote branches are auto-deleted on merge, and the flag makes `gh` run `git checkout main`, which fails in worktree contexts.

**Linking issues for auto-close:** put `Closes #N` (or `Fixes #N`) in the PR body — a bare `#N` or table reference doesn't count. The keyword must sit immediately before the number and be **repeated for each issue**: `Closes #12, closes #34` (or one per line).

#### Post-merge cleanup

Confirm `gh pr view <N> --json state -q .state` reports `"MERGED"` first. Then leave the branch (`git switch main`, or `git checkout --detach` in a manual worktree), `git branch -D <merged-branch>` (force `-D`; the squash commit makes `-d` refuse), `git branch -d -r origin/<merged-branch>` for the stale remote-tracking ref, and `git pull --ff-only`.

## Architecture Change Protocol

Before calling a task done, propose these follow-ups if it changed how components communicate, added or removed a dependency, changed build config/entitlements/tooling, added or reshaped a public type, or changed actor isolation:

1. **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — update only when a **component boundary** changed: a new service or protocol, a changed data flow, a changed actor isolation. A file appearing, moving or being renamed is not one. Surgical edits only.

2. **Tests** — cover every new public function, type, or component per the patterns in `KernovaTests/`. If deferred, state what's needed and why.

3. **AGENTS.md** — update only if a rule stated here changed.

4. **Maintenance Notes** — end the response with a `### Maintenance Notes` list: one ✅/⚠️ line per follow-up above, updated or skipped-and-why.
