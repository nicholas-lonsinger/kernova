# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Design philosophy and UI guidelines are in [SPEC.md](SPEC.md).

## Build & Test

This is an Xcode project (not Swift Package Manager). Inside Xcode, use ⌘B / ⌘U as normal. From the terminal, prefer the `Makefile` wrapper:

```bash
make build               # Build for macOS
make test                # Run the full test suite (all three test targets via Kernova.xctestplan)
make test-suite SUITE=KernovaTests/VMConfigurationTests   # Run a single suite
make test-package        # Run only the KernovaProtocol SwiftPM package tests
make format              # Rewrite Swift sources in place via swift-format
make lint                # Check Swift sources with swift-format --strict
make install-hooks       # One-time: enable .githooks/pre-push (runs `make lint` before push)
make clean               # Remove DerivedData/
```

Run `make install-hooks` once after cloning to enable the pre-push `make lint` hook (see [Development setup](README.md#development-setup) in the README for the mechanics; bypass an individual push with `git push --no-verify`).

`make test` is the canonical `xcodebuild` invocation:

```bash
xcodebuild -project Kernova.xcodeproj -scheme Kernova -destination 'platform=macOS' -derivedDataPath DerivedData -configuration Debug <build|test>
```

A single `xcodebuild test -scheme Kernova` runs all three test targets (`KernovaTests`, `KernovaGuestAgentTests`, `KernovaProtocolTests`) via `Kernova.xctestplan`. This works because `KernovaProtocol` is referenced as a top-level peer in the project (a `PBXFileReference` in `Kernova.xcodeproj`'s main group) rather than as an `XCLocalSwiftPackageReference` under Package Dependencies. In the dependency form, Xcode treats the package as upstream and hides its `.testTarget`s from the test-plan picker; in the peer form, the package's tests appear in `Edit Scheme → Test → +` as first-class targets and can be added to the test plan. If `KernovaProtocol` ever needs to be re-added, drag the folder into the Project Navigator from Finder rather than using `Add Package Dependencies → Add Local`. `make test-package` exists as a focused shortcut for iterating on package tests in isolation.

The `-derivedDataPath DerivedData` flag ensures build output goes to a deterministic local `DerivedData/` directory (already gitignored) instead of the per-path-hashed `~/Library/Developer/Xcode/DerivedData/` location. This avoids glob ambiguity when worktrees or parallel builds create multiple DerivedData folders. Xcode itself still uses the per-user default — they don't need to share.

### Build version

`CFBundleVersion` is `git rev-list --count HEAD` (the total commit count), substituted into the source `Info.plist` via `INFOPLIST_PREPROCESS`. The `Set Build Number from Git` build phase generates `KernovaBuildNumber.h` with `#define KERNOVA_BUILD_NUMBER N`, and `Kernova/App/Info.plist` references the symbol directly (`<string>KERNOVA_BUILD_NUMBER</string>`). Substitution happens inside `ProcessInfoPlistFile` so build-graph reordering can't clobber it. The `KernovaGuestAgent` target uses the same pattern with its own `AGENT_BUILD_NUMBER` (scoped to `git rev-list --count HEAD -- KernovaGuestAgent/`). The `KernovaQuickLook` extension replicates the app's pattern verbatim (unscoped total count → `KERNOVA_BUILD_NUMBER` in its own `DERIVED_FILE_DIR`) so the embedded appex's version always matches its host app. When adding a new top-level target that needs a dynamic build number, replicate this pattern instead of patching the built `Info.plist` after the fact.

Requires the toolchain listed under [Requirements](README.md#requirements) in the README. The app is Apple Silicon-only (`ARCHS = arm64` at the project level) — Virtualization.framework's macOS-guest and save/restore APIs don't exist on x86_64, and macOS 26 is the last Intel release, so no Intel slice is built and `#if arch(arm64)` guards are unnecessary. The app uses the `com.apple.security.virtualization` entitlement.

## Architecture

> Full directory structure, component map, data flow diagrams, design decisions, and test coverage details are in [ARCHITECTURE.md](ARCHITECTURE.md). Consult it before making structural changes. The summary below is a quick reference; if it conflicts with ARCHITECTURE.md, ARCHITECTURE.md is authoritative.

Kernova is a pure-AppKit app that manages virtual machines via Apple's `Virtualization.framework`, supporting macOS and Linux guests.

**Data flow:** `AppDelegate` → `VMLibraryViewModel` → `VMLifecycleCoordinator` → services + AppKit view controllers. `MainWindowController` hosts an `NSSplitViewController` with sidebar (`SidebarViewController`, a pure-AppKit source-list `NSOutlineView`) and detail (`DetailContainerViewController`) panes, plus a native `NSToolbar` with `NSToolbarItem`s. The detail pane layers a pure-AppKit `VMDisplayBackingView` (for `VZVirtualMachineView`) over the AppKit detail content — an empty-state view or `VMDetailRouterViewController`, which routes by VM status to `VMSettingsViewController`, a status placeholder, the macOS install progress VC, or the display placeholder. Lifecycle confirmation alerts are presented by `DetailAlertsPresenter`. `VMDirectoryWatcher` monitors the VMs directory for external filesystem changes and triggers reconciliation in the view model.

**Concurrency model:** Everything touching `VZVirtualMachine` is `@MainActor`. The codebase uses Swift 6 strict concurrency. Services that interact with VZ are `@MainActor`-isolated; stateless services are `Sendable` structs. Some VZ delegate callbacks use `nonisolated(unsafe)` with `MainActor.assumeIsolated` to bridge back.

**No third-party dependencies.** The Kernova app target uses only Apple system frameworks. Apple-published Swift Packages (e.g. `apple/swift-protobuf`, currently consumed by the local `KernovaProtocol/` package) are acceptable when they pull their weight; non-Apple packages still require explicit sign-off.

## Development Guidelines

### Unit Tests

When adding new functionality or modifying existing behavior, include unit tests for the changes. Follow the existing patterns in `KernovaTests/`:

- Use Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest
- Create mock implementations using protocols (see `KernovaTests/Mocks/`)
- Test models, services, and view models — UI views don't need unit tests
- Test both happy paths and error paths; use error injection in mocks (e.g., setting a `throwError` property)
- Reuse shared test helpers and factories (e.g., `makeInstance()`) rather than duplicating setup logic across test files
- Run the full test suite before committing to ensure nothing is broken

#### Test-only seams

When a test needs to observe state that is `private` in production, pick the tightest exposure that still works:

1. **`private(set) var x`** — internal getter, private setter. The idiomatic choice when production code reading the state is harmless; tests reach it via `@testable import`, no extra accessor needed.
2. **`#if DEBUG`-gated read accessor** — when the state is a test-only implementation detail that production code should *not* read. Keep the field `private` and add a `…ForTesting` computed getter wrapped in `#if DEBUG`, so the seam is physically absent from Release builds and test-only access becomes a compile-time guarantee rather than a naming convention. Place `#if DEBUG` before the doc comment and `#endif` after the accessor.

`AttachmentFileMonitor.watchedParentsForTesting` is the canonical example; the `…ForTesting` accessors in `VsockClipboardService`, `VsockGuestClipboardAgent`, and `VsockHostConnection` follow the same pattern. Because this rationale is shared, the gate itself is the documentation — don't repeat a "DEBUG-only so it can't leak" note at each site.

### Logging

The app uses Apple's `os.Logger` (subsystem `app.kernova`) with per-component categories. Each service, view model, or model that logs declares a `private static let logger`. When adding or modifying functionality, include log calls at appropriate levels:

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

When reviewing code — via review tools (`/simplify`, `/review-pr`, etc.), post-implementation review agents, external PR review feedback (bot or human), or while working on adjacent code — every finding must be triaged into one of four categories:

| Category | Action | When to use |
|----------|--------|-------------|
| **Fix now** | Apply the fix as part of the current work | Valid finding, in scope, reasonable effort |
| **Fix later** | File a GitHub issue (see [Review Debt Tracking](#review-debt-tracking) below) | Valid finding, but out of scope or too large for the current task |
| **Annotate** | Add a `RATIONALE:` comment (see [Intentional Pattern Annotations](#intentional-pattern-annotations)) for human/automated reviewer findings, or a `// periphery:ignore - <reason>` directive (see [Periphery Directives](#periphery-directives)) for dead-code scan false positives | Code looks wrong or unconventional but is correct for a project-specific reason |
| **Dismiss** | No action needed | Pure style nits, cosmetic preferences, trivial improvements with negligible impact |

#### Review Debt Tracking

Valid findings that are **out of scope** for the current task must be captured as GitHub issues rather than silently dropped.

**What to capture** (important + moderate severity):
- Bugs, correctness problems, or logic errors
- Security concerns
- Performance issues
- Meaningful refactoring opportunities or non-trivial code smells
- Missing test coverage for critical paths

**Issue format:**

~~~bash
gh issue create \
  --title "<concise description of the finding>" \
  --label "<review-debt/label>" \
  --body "$(cat <<'EOF'
## Found during
<PR #N / review of `FileName.swift` / context description>

## Description
<What the issue is and why it matters>

## Location
<Symbol/function name(s) and file path(s) — prefer names over line numbers, which drift>

## Suggested fix
<Brief suggestion if one is obvious, otherwise omit this section>
EOF
)"
~~~

**Labels** — use the most specific match:

| Label | When to use |
|-------|-------------|
| `review-debt/bug` | Correctness issues, logic errors, potential crashes |
| `review-debt/security` | Security concerns, unsafe patterns |
| `review-debt/performance` | Inefficient code paths, unnecessary allocations |
| `review-debt/refactor` | Code smells, duplication, poor abstractions |
| `review-debt/test-gap` | Missing or insufficient tests for critical code |

**Guidelines:**
- **File issues immediately** — do not list qualifying findings as "skipped" and wait for the user to ask. If a finding meets the severity criteria above, create the issue as part of the review flow before summarizing results.
- Always check for existing issues before creating duplicates
- Reference the source PR or file context in the issue body
- Keep issue titles actionable and specific (e.g., "Add error handling for disk-full scenario in BundleManager" not "Improve error handling")
- When multiple related findings exist, group them into a single issue if they share a root cause
- After creating issues, mention them in the conversation so the user is aware

#### Issue Hygiene

These rules apply to **all** issues you file — feature/enhancement as well as review-debt — so the body stays useful until the work is actually picked up:

- **Keep it to what/why.** Summary, motivation, scope, considerations, open questions. Do **not** include a "Files likely involved" sketch or other forward-looking file/API/wiring plan — design that when the work starts, not at filing time.
- **Never cite a line number.** They drift within an edit or two. Name the **symbol** instead (`startSerialReading()`, `capturesSystemKeys`) — it survives edits and is greppable.
- **Expect your own type/file names to be renamed.** A 2026 audit found ~7 issues pointing at things that no longer existed after the SwiftUI→AppKit rename (`VMSettingsView` → `VMSettingsViewController`, and `VMDetailView`/`VMConsoleView`/`SidebarView`/`VMRowView` gone) and the SPICE→vsock clipboard migration (`GuestClipboardAgent.swift` → `VsockGuestClipboardAgent.swift`). Apple/framework type names (`VZ…`, `NSPasteboardItemDataProvider`) are stable and fine to cite as the *what*.
- **Bug reports are the exception to "no file refs":** the `## Location` field above points at where the defect lives, which is the finding's evidence — keep it, but by symbol/method, not line number.
- If you deliberately omit an implementation sketch, add a one-line note saying so ("design when picked up") so a future reader knows the omission was intentional.

#### Intentional Pattern Annotations

When a review flags code that *looks* wrong or unconventional but is **intentionally correct** for a project-specific reason, add an inline comment with the `RATIONALE:` prefix explaining why. This prevents the same pattern from being re-flagged in future reviews.

**When to annotate:**
- The code contradicts a general best practice but is correct here due to framework constraints, performance requirements, or architectural decisions
- A reviewer (human or automated) would reasonably flag this without project-specific context
- The reason is not already documented in CLAUDE.md, ARCHITECTURE.md, or an adjacent comment

**Format:**

```swift
// RATIONALE: VZVirtualMachine delegates are not actor-isolated by the framework,
// so we use nonisolated(unsafe) and bridge back via MainActor.assumeIsolated.
nonisolated(unsafe) func guestDidStop(_ virtualMachine: VZVirtualMachine) {
```

**Guidelines:**
- Keep annotations concise — explain *why* the pattern is correct, not *what* the code does
- If the same rationale applies project-wide (not just at one call site), consider adding it to CLAUDE.md or ARCHITECTURE.md instead of repeating the comment on every instance
- `RATIONALE:` comments are greppable — use `grep -r "RATIONALE:"` to audit all intentional deviations
- Do not use `RATIONALE:` for general explanatory comments — reserve it strictly for patterns that would otherwise be flagged as issues

#### Periphery Directives

When the dead-code scan flags a symbol that is alive through machinery Periphery's symbol graph cannot see — protocol witnesses invoked by Swift's compiler-emitted code (string interpolation, `Codable`), members reached through type inference on argument labels, declarations referenced only from a test target Periphery does not currently scan, or symbols intentionally retained for API symmetry — annotate the declaration with `// periphery:ignore - <reason>` instead of deleting it. This is the Periphery-specific counterpart to `RATIONALE:`: same spirit (silence a finding that would otherwise be re-raised every scan), different syntax that the tool itself recognizes.

**When to annotate vs. fix vs. dismiss:**
- **Annotate** when the symbol is genuinely used through one of the invisible paths above, OR when the surface is intentionally complete (e.g. all `os.Logger` levels exposed even if a particular call isn't used today).
- **Fix** when the finding is real — delete the symbol, or demote `public` to `internal` if only the access level is redundant.
- **Dismiss** does not apply: every annotation must include a reason, since silently retained symbols become a maintenance hazard.

**Format:**

```swift
/// `true` when no buffered bytes remain.
// periphery:ignore - Used by `VsockFrameTests` via `@testable import`,
// which Periphery's scheme-based scan doesn't currently index for the
// SwiftPM package test target.
var isEmpty: Bool { buffer.count == readOffset }
```

Place the directive **between** the doc comment (`///`) and the declaration so DocC still associates the doc with the symbol.

**Guidelines:**
- Keep the rationale on the same comment block as the directive — multi-line if needed, but no blank line between `// periphery:ignore` and the reason text
- Greppable via `grep -r "periphery:ignore"` for periodic auditing — when the underlying machinery becomes visible to Periphery (e.g. a scan-coverage gap is closed), revisit the annotations and remove any that are no longer needed
- Prefer per-symbol annotations over re-toggling broad config flags like `retain_public` — see `.periphery.yml` for the project-level guidance

## Git Workflow

### Branch Naming

Worktrees start on an auto-generated `worktree-<name>` branch (the harness also
mangles any `/` in the name to `+`). **Leave that scratch branch named as-is —
never `git branch -m` it.** `EnterWorktree` tracks the branch by the name it
generated, and `ExitWorktree(remove)` only tears the local branch down while that
name is intact; rename it and the removal silently orphans the branch, which is
how merged local branches pile up. Don't try to pick a name before starting
anyway — the right one depends on the full scope of the work, which you only know
once it's ready to push.

When the work is ready to push, give the **remote** branch a clean
`<type>/<short-description>` name with an explicit refspec while the local branch
keeps its `worktree-` name. `<type>` matches the commit type prefixes (e.g.,
`feat`, `fix`, `refactor`); keep the description concise (2-4 words, kebab-case)
so the PR's purpose is clear at a glance:

```
feat/vm-snapshot-support
fix/display-sizing-on-switch
refactor/extract-lifecycle-coordinator
```

```bash
git push -u origin HEAD:<type>/<short-description>   # remote/PR gets the clean name; local stays worktree-…
git push                                              # later pushes follow the upstream — no refspec needed
```

The local↔remote name mismatch is deliberate: the local `worktree-` branch is a
throwaway that `ExitWorktree` deletes on exit, so only the remote name — the one
humans and GitHub see — has to be clean. After the first `-u` push sets the
upstream to `origin/<type>/<short-description>`, plain `git push` and
`git push -f` (after a rebase) follow it, so you spell the refspec out only once.
**Always push before exiting the worktree** so the work is safe on origin:
`ExitWorktree(remove)` discards the local commit, and it drops *unpushed* commits
silently.

**Never push the `worktree-`-prefixed scratch name to origin** — that means no
bare `git push -u origin HEAD` on the first push; always name the clean remote
ref in the refspec. A PR's head branch must always be the clean
`<type>/<short-description>` name. (Renaming a branch on GitHub *after* a PR
exists does not retarget the PR — it closes it — so name it correctly at first
push.)

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

### Type prefixes

| Prefix     | Usage                                      |
|------------|--------------------------------------------|
| `feat`     | New feature or capability                  |
| `fix`      | Bug fix                                    |
| `refactor` | Code restructuring with no behavior change |
| `docs`     | Documentation only                         |
| `test`     | Adding or updating tests                   |
| `chore`    | Build, CI, tooling, or dependency updates  |
| `style`    | Formatting, whitespace, or cosmetic changes|

### Example

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

### Scoping the message

Commit messages must reflect the full intent and scope of all changes, not just the last operation performed. Before writing a commit message, review both the conversation context (what the user asked for, the steps taken) and the staged diff holistically. Lead with the primary purpose; secondary details (naming conventions, formatting choices) belong in the body.

End every commit message with a `Co-Authored-By: Claude <Model> <noreply@anthropic.com>` trailer, where `<Model>` is the model actually authoring the commit — Claude Code states the current model's exact trailer in each session (e.g. `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`); use that rather than copying a model name from documentation or earlier commits. It is **not** appended automatically — add it explicitly (e.g. `git commit --trailer "Co-Authored-By: Claude <Model> <noreply@anthropic.com>"`). Include it exactly once; do not duplicate it in the message body.

### Merging Pull Requests

When merging PRs with `gh pr merge`, always squash-merge with `--squash --subject` using the PR title and appending the PR number in parentheses (e.g., `--squash --subject "fix: Title (#11)"`), matching the repo's existing convention.

**Do not use `--delete-branch`.** The repo has `delete_branch_on_merge` enabled on GitHub, so remote branches are auto-deleted. The `--delete-branch` flag causes `gh` to run `git checkout main` locally, which fails in worktree contexts.

**Linking issues for auto-close:** When a PR resolves GitHub issues, include `Closes #N` (or `Fixes #N`) in the PR body — not just a table reference like `| #N |`. GitHub only auto-closes issues when the merge commit or PR body contains the exact keywords `closes`, `fixes`, or `resolves` followed by `#N`. Place them in the summary section or as a standalone line (e.g., `Closes #12, #34, #56`).

#### Post-merge cleanup

After a successful merge, confirm it landed, then tear down the branch and sync `main`:

1. `gh pr view <N> --json state -q .state` — confirm `"MERGED"` before deleting anything.

**Before removing any worktree in which the app was built or launched** (e.g. for verification — this applies to abandoned worktrees too, not just merged ones), unregister its build products from LaunchServices. Otherwise LS keeps a ghost registration for the deleted path that can outrank the primary checkout's build and silently break `.kernova` UTI resolution (Quick Look previews) and app-name resolution (TCC/screen-capture grants) system-wide:

```bash
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -u "$PWD/DerivedData/Build/Products/Debug/Kernova.app"
```

`-u` is harmless if the path was never registered, so always run it. If Xcode built the worktree directly (rather than `make build`), also trash the worktree's per-user `~/Library/Developer/Xcode/DerivedData/Kernova-<hash>/` folder — it holds another registered copy that outlives the worktree (check `WorkspacePath` in each `Kernova-<hash>/info.plist` to find the right one).

**In an `EnterWorktree` session** (the usual case), let the tool do the teardown, then sync:

2. `ExitWorktree` with `action: "remove"`. Squash-merge leaves the worktree's commit off `main` by SHA, so the tool refuses unless you also pass `discard_changes: true` — that's expected and safe here, since the content already landed on `main` as the squash commit. This returns the session to the primary checkout and deletes the worktree and its scratch branch in one step (the branch deletion works because the scratch branch still carries its original `worktree-` name — see [Branch Naming](#branch-naming)).
3. Now in the primary checkout: `git checkout main` (if not already on it), then `git pull --prune --ff-only` to fast-forward onto the squash commit and drop the now-stale `origin/<type>/<short-description>` remote-tracking ref.

**Working directly in a checkout** (no `EnterWorktree` session), delete the branch by hand instead:

2. Get off the merged branch first: `git switch main`, or `git checkout --detach` in a manually-created worktree (you can't switch to `main` there — the primary checkout holds it).
3. `git branch -D <merged-branch>` — force `-D`, since the squash commit makes `-d` reject the branch as "not fully merged".
4. `git branch -d -r origin/<merged-branch>` — drop the stale remote-tracking ref (GitHub auto-deletes the remote branch on merge).
5. `git pull --ff-only`.

### Post-Commit

After a commit/push, if any new preferences or insights emerged during the work, ask the user if they'd like to add them to memory.

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

1. **[ARCHITECTURE.md](ARCHITECTURE.md)** — Read the relevant sections first, then propose specific, targeted updates to reflect the change. Update the directory structure, component map, design decisions, or test coverage sections as needed. Do not rewrite the entire file — make surgical edits.

2. **Testing** — For any new public function, type, or component:
   - Write tests following the patterns in KernovaTests/ (Swift Testing, mocks, factories)
   - If tests are deferred, explicitly state what's needed and why it was skipped

3. **CLAUDE.md** — Update only if build commands, the concurrency model summary, or the data flow summary changed. Preserve commit message format and development guidelines as-is.

4. **Maintenance Notes** — At the end of your response, include a summary:

   ### Maintenance Notes
   - ✅ Updated ARCHITECTURE.md directory structure
   - ✅ Added tests for NewComponent
   - ⚠️ No tests yet for `newFunction()` — needs mock for ExternalDependency
   - ✅ CLAUDE.md unchanged (no structural impact)
