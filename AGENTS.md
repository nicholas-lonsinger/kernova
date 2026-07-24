# AGENTS.md

This is the tool-neutral operating guide for anyone — human or AI agent — working in this repository: build commands, architecture summary, and the coding, testing, review, and git conventions. Claude Code loads it via `CLAUDE.md`'s import; other agents read it directly. Deep-dive documentation lives in [docs/](docs/README.md) — follow the links below on demand instead of guessing.

> Design philosophy and UI guidelines are in [docs/SPEC.md](docs/SPEC.md).
>
> Clipboard subsystem principles (host↔guest copy/paste — the authoritative rules for any clipboard work) are in [docs/CLIPBOARD.md](docs/CLIPBOARD.md).

## Build & Test

This is an Xcode project (not Swift Package Manager). Inside Xcode, use ⌘B / ⌘U as normal. From the terminal, prefer the `Makefile` wrapper (`make help` lists every target):

```bash
make build               # Build for macOS
make test                # Run the full test suite (all three test targets via Kernova.xctestplan)
make test-suite SUITE=KernovaTests/VMConfigurationTests   # Run a single suite
make test-package        # Run only the KernovaKit SwiftPM package tests
make format              # Rewrite Swift sources in place via swift-format
make lint                # Check Swift sources (swift-format --strict) + shell scripts (bash -n; shellcheck when installed, required on CI)
make install-hooks       # One-time: enable .githooks/ (pre-push lint; post-checkout worktree setup)
make doctor              # Check the local toolchain (macOS, Xcode, Swift, swift-format) and repo setup (hooks, .worktreeinclude)
make clean               # Remove DerivedData/
```

Run `make install-hooks` once after cloning to enable the checked-in `.githooks/`: pre-push runs `make lint` (bypass an individual push with `git push --no-verify`), and post-checkout sets up new git worktrees so they inherit the gitignored local files and sign without a manual step. `DEVELOPMENT_TEAM` is not hardcoded in the project — `make bootstrap` derives it from your own signing certificate into the gitignored `Config/Local.xcconfig`, and `make build`/`make test`/`make test-suite` run it automatically. Raw `xcodebuild` (and Xcode's own ⌘B/⌘R) assume it has already run, so on a fresh clone (where hooks aren't active yet) run `make bootstrap` once first — otherwise `DEVELOPMENT_TEAM` resolves empty and the Manual/profile-less Debug targets fail to sign. The full build machinery — the hooks and `.worktreeinclude`, the bootstrap derivation, why a single `xcodebuild test` runs all three test targets, and the DerivedData layout / IDE build-state sharing — is documented in [docs/BUILD.md](docs/BUILD.md).

`make test` is the canonical `xcodebuild` invocation:

```bash
xcodebuild -project Kernova.xcodeproj -scheme Kernova -destination 'platform=macOS' -derivedDataPath DerivedData/Kernova -configuration Debug <build|test>
```

### Build version

`CFBundleVersion` is derived from git — squash-merge aware — by a single shared script, `Tools/set-build-number.sh <app|agent>`, called from every target's `Set Build Number from Git` build phase. When adding a new top-level target that needs a dynamic build number, call the shared script with the appropriate mode instead of patching the built `Info.plist` after the fact. The derivation rules, the app/agent mode split, and the guest agent's own `MARKETING_VERSION` bump conventions are in [docs/BUILD.md](docs/BUILD.md).

Requires the toolchain listed under [Requirements](README.md#requirements) in the README. The app is Apple Silicon-only (`ARCHS = arm64` at the project level) — Virtualization.framework's macOS-guest and save/restore APIs don't exist on x86_64, and macOS 26 is the last Intel release, so no Intel slice is built and `#if arch(arm64)` guards are unnecessary. The app uses the `com.apple.security.virtualization` entitlement.

## Architecture

> Full directory structure, component map, data flow diagrams, design decisions, and test coverage details are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Consult it before making structural changes. The summary below is a quick reference; if it conflicts with ARCHITECTURE.md, ARCHITECTURE.md is authoritative.

Kernova is a pure-AppKit app that manages virtual machines via Apple's `Virtualization.framework`, supporting macOS and Linux guests.

**Data flow:** `AppDelegate` → `VMLibraryViewModel` → `VMLifecycleCoordinator` → services + AppKit view controllers. `MainWindowController` hosts an `NSSplitViewController` with sidebar (`SidebarViewController`, a pure-AppKit source-list `NSOutlineView`) and detail (`DetailContainerViewController`) panes, plus a native `NSToolbar` with `NSToolbarItem`s. The detail pane layers a pure-AppKit `VMDisplayBackingView` (for `VZVirtualMachineView`) over the AppKit detail content — an empty-state view or `VMDetailRouterViewController`, which routes by VM status to `VMSettingsViewController`, a status placeholder, the macOS install progress VC, or the display placeholder. Lifecycle confirmation alerts are presented by `DetailAlertsPresenter`. `VMDirectoryWatcher` monitors the VMs directory for external filesystem changes and triggers reconciliation in the view model.

**Concurrency model:** Everything touching `VZVirtualMachine` is `@MainActor`. The codebase uses Swift 6 strict concurrency. Services that interact with VZ are `@MainActor`-isolated; stateless services are `Sendable` structs. Some VZ delegate callbacks use `nonisolated(unsafe)` with `MainActor.assumeIsolated` to bridge back.

**No third-party dependencies.** The Kernova app target uses only Apple system frameworks. Apple-published Swift Packages (e.g. `apple/swift-protobuf`, currently consumed by the local `KernovaKit/` package) are acceptable when they pull their weight; non-Apple packages still require explicit sign-off.

## App Sandbox rules

Kernova is intended for **Mac App Store distribution**, and the main app **runs under the App Sandbox in every build configuration** (#89) — write code that lives within it. The full entitlement inventory, the per-configuration app-group and signing story, and the launch model are in [docs/SANDBOX.md](docs/SANDBOX.md). The rules for new code:

- **User-picked files persist their grant as an app-scoped security bookmark** stored next to the raw path (`SecurityScopedBookmark.capture` at the panel pick site; see `StorageDisk.bookmark` and friends). Access sites resolve through the RAII `ScopedAccess`: VM-runtime scopes are owned by `VMInstance.runtimeFileAccess` (`RuntimeFileAccess`), opened by `openRuntimeFileAccess()` per boot attempt (which also heals stale bookmarks and moved paths) and released exactly once in `tearDownSession()`; momentary probes (existence checks, trashing) open and release a `ScopedAccess` locally. A `nil`/dead bookmark falls through to the raw-path attempt, which under the sandbox surfaces the *existing* missing-file UX (start-time not-found errors, the settings warning icon) and re-picking mints a fresh bookmark — **never add special-case handling for pre-sandbox data** (no decode-time migrations, no `Container Migration.plist`; users move their VMs via the documented drag-and-drop import).
- **App-internal state belongs in the container.** `.applicationSupportDirectory` (the VM library), `FileManager.temporaryDirectory`, and the app-group container all resolve correctly under the sandbox. Never build paths off `homeDirectoryForCurrentUser` expecting the *real* home — in a sandboxed app it is the container home (ask the system for the folder instead, e.g. `.downloadsDirectory`).
- **Prefer in-process Apple framework APIs over shelling out** to system command-line tools (`Process` / `NSTask` → `/usr/bin/ditto`, `unzip`, `tar`, …), which a sandboxed app cannot usefully spawn, and over adding entitlements unavailable to MAS apps. (This is also why VM disks are created by decompressing bundled ASIF templates — macOS 26 has no public in-process ASIF-creation API, and `diskutil` is unreachable from the sandbox.)

## Development Guidelines

### Unit Tests

When adding new functionality or modifying existing behavior, include unit tests for the changes. Follow the existing patterns in `KernovaTests/`:

- Use Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest
- Create mock implementations using protocols (see `KernovaTests/Mocks/`)
- Test models, services, and view models — UI views don't need unit tests
- Test both happy paths and error paths; use error injection in mocks (e.g., setting a per-method `<method>Error` property such as `startError`)
- Reuse shared test helpers and factories (e.g., `makeInstance()`) rather than duplicating setup logic across test files
- Run the full test suite before committing to ensure nothing is broken

**Async waits in tests must be event-driven, not poll loops.** CI runners have heavy `@MainActor` scheduling jitter, and with a poll loop the timeout deadline *is* the pass/fail criterion — a starved scheduler fails a test whose condition would have become true. Before writing any test wait, pick the seam (`waitForChange`, `AsyncGate`, or awaiting the production `Task`) per the table in [docs/TESTING.md](docs/TESTING.md); polling is acceptable only for genuinely signal-less predicates and needs a one-line `RATIONALE:` naming which signal-less category applies. The same document covers the companion rule — an injected production timeout must be either the behavior under test or sized past any scheduler stall (production default or ≥60s), never a small "tidy" value — and the test-only seam conventions (`private(set)` vs a `#if DEBUG …ForTesting` accessor).

### Logging

The app uses Apple's `os.Logger` with per-component categories. Each service, view model, or model that logs declares a `private static let logger`. Subsystems are per-target:

| Subsystem | Who logs there |
|-----------|----------------|
| `app.kernova` | The host app and all `KernovaKit` shared code — including KernovaKit types running *inside* the guest agent's processes |
| `app.kernova.fileprovider` | The host clipboard File Provider extension |
| `app.kernova.macosagent` | The guest agent's own components |
| `app.kernova.macosagent.fileprovider` | The guest agent's File Provider extension |
| `app.kernova.guest` | Host-side re-logging of forwarded guest records (the log-forwarding toggle; category = VM name) |

When capturing logs with `log stream`/`log show`, filter with `subsystem BEGINSWITH "app.kernova"`. An exact `subsystem == "app.kernova"` match silently drops the agent's and both extensions' records — and because KernovaKit code inside those processes still matches, the truncated capture *looks* complete.

When adding or modifying functionality, include log calls at appropriate levels:

| Level | When to use | Persistence |
|-------|-------------|-------------|
| `.debug` | Method entry with parameter snapshots, intermediate states, per-item iteration results. Diagnostic detail only useful when actively investigating. | Discarded unless streaming via Console.app or `log stream` |
| `.info` | General operational context: routine progress, non-critical outcomes, sub-step completion. | In-memory only; evicted under pressure |
| `.notice` | Definitive lifecycle events: VM started/stopped/paused/resumed/saved, bundle created/deleted, app launch. Events you need for post-mortem analysis. | Persisted to disk |
| `.warning` | Unexpected but recoverable situations: missing files, fallback paths taken, degraded operation. | Persisted to disk |
| `.error` | Failures: operations that did not complete, exceptions caught, error states entered. | Persisted to disk |
| `.fault` | Programming errors: impossible states, compile-time-known inputs that failed lookup. Paired with `assertionFailure`. | Persisted to disk; always visible; never redacted |

**Guidelines:**
- Every new service or view model should declare its own `private static let logger = Logger(subsystem: "app.kernova", category: "ComponentName")`
- State transitions and irreversible actions (creating/deleting bundles, starting/stopping VMs) should be `.notice`
- Method entry points in complex flows should have `.debug` logs with relevant parameter values
- Do not use `print()`, `NSLog()`, or file-based logging

### Defensive Unwrapping

When calling an API that returns an optional but is invoked with compile-time-known inputs (SF Symbol names, known resource identifiers, hardcoded keys), use `assertionFailure` with a graceful fallback:

```swift
guard let value = knownGoodAPI("compile-time-constant") else {
    logger.fault("Descriptive message '\(context, privacy: .public)'")
    assertionFailure("Descriptive message: \(context)")
    return fallbackValue
}
```

- **Debug builds** crash immediately at the call site, catching typos and deployment-target mismatches on first test run
- **Release builds** return the fallback and log at `.fault` level for post-mortem diagnosis
- Do not force-unwrap (`!`) — it crashes end users. Do not silently return a fallback without `assertionFailure` — it masks bugs during development.

### File Operations

- When deleting files, prefer `trash` over `rm` whenever possible (moves to Trash instead of permanent deletion).

### Review Feedback Handling

When reviewing code — via review tooling, post-implementation review agents, external PR review feedback (bot or human), or while working on adjacent code — every finding must be triaged into one of four categories:

| Category | Action | When to use |
|----------|--------|-------------|
| **Fix now** | Apply the fix as part of the current work | Valid finding, in scope, reasonable effort |
| **Fix later** | File a GitHub issue immediately (format and labels in [docs/REVIEW.md](docs/REVIEW.md)) | Valid finding, but out of scope or too large for the current task |
| **Annotate** | Add a `RATIONALE:` comment — a **last resort**, allowed only when it clears all four conditions in [docs/REVIEW.md](docs/REVIEW.md) and disclosed in the commit/PR summary. Or `// periphery:ignore - <reason>` for dead-code-scan false positives (lower bar; same file) | The concern was *actually* raised (not "a reviewer would flag this"), no test or doc is a better home, there is re-checkable evidence to cite, and "fixing" it would break something real |
| **Dismiss** | No action needed | Pure style nits, cosmetic preferences, trivial improvements with negligible impact — and anything failing the severity bar below that doesn't clear the annotation bar |

**The severity bar — Dismiss and Annotate are real options.** A finding earns **Fix now** or **Fix later** only if it is both **reachable** (a user doing normal things, or a supported automated flow, can actually hit it) and **consequential** (worse than a transient cosmetic glitch, a logged self-recovering retry, or a state an obvious user action recovers from). Findings about hypothetical future code, adversarial scheduling no real flow produces, degenerate inputs, or pre-existing behavior merely surfaced by an unrelated diff default to **Dismiss**; escalating to **Annotate** takes a pattern that has *actually* been re-flagged across reviews, not one that might be. And when a review chain has moved from defects in the code to meta-findings about prior fixes, stop the chain — dismiss rather than filing the next link, and resist annotating it, since a comment defending the previous fix is the same dead end in another form.

Read [docs/REVIEW.md](docs/REVIEW.md) before filing review-debt issues or annotating: it has the full severity bar with worked examples, the issue template and label conventions, the issue-hygiene rules (report observed behavior and facts, never a diagnosis — unverified causal theories only under a caveated hypothesis heading; cite symbols, never line numbers; keep bodies to what/why with no forward-looking implementation sketch — these apply to *every* issue you file), and the annotation formats.

**Reading an existing `RATIONALE:` — it is evidence, not authority.** You will meet these far more often than you write one, so the rule belongs here rather than only in `docs/REVIEW.md`. An annotation is a claim *as of when it was written*, with the same standing as an old issue: accurate then, not authoritative now. It never settles a contradicting observation — if the code looks wrong *today*, investigate; the comment is a head start on where to look, never a reason to stop looking. Re-check its claim whenever you edit the code it covers, then correct and re-date it or delete it. Most predate the current bar and cite no evidence and no date: treat those as **unverified**, worth no more than an ordinary comment until someone re-confirms them. Deleting one that no longer holds is maintenance, not churn.

## Git Workflow

### Branch Naming

Remote/PR branches use a clean `<type>/<short-description>` name. `<type>` matches the commit type prefixes below (e.g., `feat`, `fix`, `refactor`); keep the description concise (2-4 words, kebab-case) so the PR's purpose is clear at a glance:

```
feat/vm-snapshot-support
fix/display-sizing-on-switch
refactor/extract-lifecycle-coordinator
```

A PR's head branch must always carry this clean name. (Renaming a branch on GitHub *after* a PR exists does not retarget the PR — it closes it — so name it correctly at first push.)

### Commit Messages

These conventions apply to **all** forms of committing: local commits, PR squash/merge commits, and any other git operations that produce commits.

Use the following format for all commits:

```
<type>: <concise subject line>

## Summary
- <user-facing intent: what capability was added/fixed/changed and why>

## Changes
- <implementation details: specific files, types, or components modified>

## Test plan
- [ ] <verification step as a checkbox>
```

A `## Notes` section may be added optionally if there are caveats, follow-ups, or things reviewers should know.

**`## Notes` is required when the change adds a `RATIONALE:` comment.** List each one — file, symbol, and the evidence it cites — so the maintainer can strike it at review time rather than discovering it in a `grep` months later. There is no approval gate on writing one; this disclosure is what replaces it, so a silent addition is the one thing that isn't allowed.

#### Type prefixes

| Prefix     | Usage                                      |
|------------|--------------------------------------------|
| `feat`     | New feature or capability                  |
| `fix`      | Bug fix                                    |
| `refactor` | Code restructuring with no behavior change |
| `docs`     | Documentation only                         |
| `test`     | Adding or updating tests                   |
| `chore`    | Build, CI, tooling, or dependency updates  |
| `style`    | Formatting, whitespace, or cosmetic changes|

#### Example

```
feat: Add VM snapshot support

## Summary
- Add the ability to take and restore snapshots of running virtual machines
- Enables users to save and revert VM state at any point

## Changes
- Add SnapshotService with create/restore/delete operations
- Add snapshot UI to VMDetailView toolbar
- Persist snapshot metadata in VMConfiguration

## Test plan
- [ ] Built successfully on macOS 26
- [ ] Tested snapshot create/restore cycle with macOS and Linux guests
- [ ] All existing tests pass
```

#### Scoping the message

Commit messages must reflect the full intent and scope of all changes, not just the last operation performed. Before writing a commit message, review both the task context (what was asked for, the steps taken) and the staged diff holistically. Lead with the primary purpose; secondary details (naming conventions, formatting choices) belong in the body.

An AI agent authoring a commit ends the message with a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer — no model name, substituting the agent's own identity if it isn't Claude. The trailer is **not** appended automatically — add it explicitly (e.g. `git commit --trailer "Co-Authored-By: Claude <noreply@anthropic.com>"`). Include it exactly once; do not duplicate it in the message body.

### Merging Pull Requests

When merging PRs with `gh pr merge`, always squash-merge with `--squash --subject` using the PR title and appending the PR number in parentheses (e.g., `--squash --subject "fix: Title (#11)"`), matching the repo's existing convention.

**Do not use `--delete-branch`.** The repo has `delete_branch_on_merge` enabled on GitHub, so remote branches are auto-deleted. The `--delete-branch` flag causes `gh` to run `git checkout main` locally, which fails in worktree contexts.

**Linking issues for auto-close:** When a PR resolves GitHub issues, include `Closes #N` (or `Fixes #N`) in the PR body — not just a table reference like `| #N |`. GitHub only auto-closes an issue when the merge commit or PR body has the keyword `closes`, `fixes`, or `resolves` immediately before its `#N`, **repeated for each issue**: `Closes #12, closes #34, closes #56` (or one `Closes #N` per line).

#### Post-merge cleanup

After a successful merge, confirm it landed, then sync `main` and tear down the merged branch:

1. `gh pr view <N> --json state -q .state` — confirm `"MERGED"` before deleting anything.
2. Get off the merged branch first: `git switch main`, or `git checkout --detach` in a manually-created worktree (you can't switch to `main` there — the primary checkout holds it).
3. `git branch -D <merged-branch>` — force `-D`, since the squash commit makes `-d` reject the branch as "not fully merged".
4. `git branch -d -r origin/<merged-branch>` — drop the stale remote-tracking ref (GitHub auto-deletes the remote branch on merge).
5. `git pull --ff-only`.

## Architecture Change Protocol

After completing any task that hits one or more of the following triggers, suggest follow-up updates before considering the task complete.

### Triggers
- Added, removed, renamed, or moved a file or directory
- Changed how components communicate (new API surface, changed data flow, new service)
- Added or removed a dependency or framework
- Changed build configuration, entitlements, or tooling
- Created a new public type/protocol or significantly changed an existing one
- Changed the concurrency model or actor isolation of a component

### Required Follow-ups

1. **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — Read the relevant sections first, then propose specific, targeted updates to reflect the change. Update the directory structure, component map, design decisions, or test coverage sections as needed. Do not rewrite the entire file — make surgical edits.

2. **Testing** — For any new public function, type, or component:
   - Write tests following the patterns in KernovaTests/ (Swift Testing, mocks, factories)
   - If tests are deferred, explicitly state what's needed and why it was skipped

3. **AGENTS.md** — Update only if build commands, the concurrency model summary, or the data flow summary changed. Preserve commit message format and development guidelines as-is.

4. **Maintenance Notes** — At the end of your response, include a summary:

   ### Maintenance Notes
   - ✅ Updated docs/ARCHITECTURE.md directory structure
   - ✅ Added tests for NewComponent
   - ⚠️ No tests yet for `newFunction()` — needs mock for ExternalDependency
   - ✅ AGENTS.md unchanged (no structural impact)
