# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Design philosophy and UI guidelines are in [SPEC.md](SPEC.md). Architecture is in [ARCHITECTURE.md](ARCHITECTURE.md). Procedure references live in `docs/`: [testing](docs/testing.md), [review feedback handling](docs/reviewing.md), and [git workflow mechanics](docs/git-workflow.md) — read the relevant one before doing that kind of work.

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

One `xcodebuild test` run covers all three test targets (`KernovaTests`, `KernovaGuestAgentTests`, `KernovaProtocolTests`) via `Kernova.xctestplan` — how that's wired, and how to re-add the `KernovaProtocol` package if it's ever removed, is in [docs/testing.md](docs/testing.md#test-targets-and-the-test-plan).

The `-derivedDataPath DerivedData` flag keeps build output in a deterministic local `DerivedData/` directory (gitignored) instead of the per-path-hashed `~/Library/Developer/Xcode/DerivedData/` location, avoiding glob ambiguity when worktrees or parallel builds create multiple DerivedData folders. Xcode itself still uses the per-user default — they don't need to share.

### Build version

`CFBundleVersion` is `git rev-list --count HEAD` (the total commit count), substituted into the source `Info.plist` via `INFOPLIST_PREPROCESS`: the `Set Build Number from Git` build phase generates a header defining `KERNOVA_BUILD_NUMBER`, which `Kernova/App/Info.plist` references directly. Substitution happens inside `ProcessInfoPlistFile` so build-graph reordering can't clobber it. `KernovaGuestAgent` uses the same pattern with its own `AGENT_BUILD_NUMBER` (scoped to `git rev-list --count HEAD -- KernovaGuestAgent/`). When adding a new top-level target that needs a dynamic build number, replicate this pattern instead of patching the built `Info.plist` after the fact.

Requires the toolchain listed under [Requirements](README.md#requirements) in the README (Apple Silicon is needed for macOS guest support). The app uses the `com.apple.security.virtualization` entitlement.

## Architecture

> Full directory structure, component map, data flow diagrams, and design decisions are in [ARCHITECTURE.md](ARCHITECTURE.md). Consult it before making structural changes. The summary below is a quick reference; if it conflicts with ARCHITECTURE.md, ARCHITECTURE.md is authoritative.

Kernova is a pure-AppKit app that manages virtual machines via Apple's `Virtualization.framework`, supporting macOS and Linux guests.

**Data flow:** `AppDelegate` → `VMLibraryViewModel` → `VMLifecycleCoordinator` → services + AppKit view controllers. `MainWindowController` hosts an `NSSplitViewController` with sidebar (`SidebarViewController`, a pure-AppKit source-list `NSOutlineView`) and detail (`DetailContainerViewController`) panes, plus a native `NSToolbar` with `NSToolbarItem`s. The detail pane layers a pure-AppKit `VMDisplayBackingView` (for `VZVirtualMachineView`) over the AppKit detail content — an empty-state view or `VMDetailRouterViewController`, which routes by VM status to `VMSettingsViewController`, a status placeholder, the macOS install progress VC, or the display placeholder. Lifecycle confirmation alerts are presented by `DetailAlertsPresenter`. `VMDirectoryWatcher` monitors the VMs directory for external filesystem changes and triggers reconciliation in the view model.

**Concurrency model:** Everything touching `VZVirtualMachine` is `@MainActor`. The codebase uses Swift 6 strict concurrency. Services that interact with VZ are `@MainActor`-isolated; stateless services are `Sendable` structs. Some VZ delegate callbacks use `nonisolated(unsafe)` with `MainActor.assumeIsolated` to bridge back.

**No third-party dependencies.** The Kernova app target uses only Apple system frameworks. Apple-published Swift Packages (e.g. `apple/swift-protobuf`, currently consumed by the local `KernovaProtocol/` package) are acceptable when they pull their weight; non-Apple packages still require explicit sign-off.

## Development Guidelines

### Unit Tests

When adding new functionality or modifying existing behavior, include unit tests for the changes. The essentials (full patterns, the test plan, and seam guidance in [docs/testing.md](docs/testing.md)):

- Use Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest
- Create mock implementations using protocols (see `KernovaTests/Mocks/`); inject errors via `throwError`
- Test models, services, and view models — UI views don't need unit tests
- Test both happy paths and error paths; reuse shared factories (`makeInstance()`, …) rather than duplicating setup
- Timing-sensitive waits must be event-driven (`AsyncGate`, or `await` the production `Task` via a `#if DEBUG` seam) — never poll-with-timeout, and never fix a CI flake by raising a timeout. See [docs/testing.md](docs/testing.md#timing-sensitive-waits-event-driven-not-polling)
- When a test needs `private` production state, pick the tightest seam: `private(set)`, or a `#if DEBUG`-gated `…ForTesting` accessor — decision rule and canonical examples in [docs/testing.md](docs/testing.md#test-only-seams)
- Run the full test suite before committing

### Logging

The app uses Apple's `os.Logger` (subsystem `com.kernova.app`) with per-component categories. Each service, view model, or model that logs declares a `private static let logger = Logger(subsystem: "com.kernova.app", category: "ComponentName")`.

| Level | When to use | Persistence |
|-------|-------------|-------------|
| `.debug` | Method entry with parameter snapshots, intermediate states, per-item iteration results. Diagnostic detail only useful when actively investigating. | Discarded unless streaming via Console.app or `log stream` |
| `.info` | General operational context: routine progress, non-critical outcomes, sub-step completion. | In-memory only; evicted under pressure |
| `.notice` | Definitive lifecycle events: VM started/stopped/paused/resumed/saved, bundle created/deleted, app launch. Events you need for post-mortem analysis. | Persisted to disk |
| `.warning` | Unexpected but recoverable situations: missing files, fallback paths taken, degraded operation. | Persisted to disk |
| `.error` | Failures: operations that did not complete, exceptions caught, error states entered. | Persisted to disk |
| `.fault` | Programming errors: impossible states, compile-time-known inputs that failed lookup. Paired with `assertionFailure`. | Persisted to disk; always visible; never redacted |

State transitions and irreversible actions (creating/deleting bundles, starting/stopping VMs) are `.notice`; method entry points in complex flows get `.debug` with relevant parameter values. Do not use `print()`, `NSLog()`, or file-based logging.

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

### Localization

The app ships English-only — there are no `.lproj` directories or `Localizable.strings` files. Don't wrap user-facing strings in `NSLocalizedString(...)` unless explicitly setting up localization; raw `String` literals are the convention. If real translations ever land, file `review-debt/refactor` issues for bulk-wrapping the existing strings.

### Review Feedback Handling

When reviewing code — via review tools (`/simplify`, `/review-pr`, etc.), post-implementation review agents, external PR review feedback (bot or human), or while working on adjacent code — every finding must be triaged into one of four categories:

| Category | Action | When to use |
|----------|--------|-------------|
| **Fix now** | Apply the fix as part of the current work | Valid finding, in scope, reasonable effort |
| **Fix later** | File a GitHub issue immediately — issue format and `review-debt/*` labels in [docs/reviewing.md](docs/reviewing.md#review-debt-tracking) | Valid finding, but out of scope or too large for the current task |
| **Annotate** | `RATIONALE:` comment for human/automated reviewer findings, or `// periphery:ignore - <reason>` for dead-code scan false positives — formats in [docs/reviewing.md](docs/reviewing.md#intentional-pattern-annotations) | Code looks wrong or unconventional but is correct for a project-specific reason |
| **Dismiss** | No action needed | Pure style nits, cosmetic preferences, trivial improvements with negligible impact |

File qualifying issues **immediately** as part of the review flow — do not list findings as "skipped" and wait for the user to ask — and mention created issues in the conversation so the user is aware.

## Git Workflow

### Branch Naming

Worktrees start on an auto-generated `worktree-<name>` scratch branch — work on it as-is, without picking a name up front. When the work is ready to push, rename it to a clean `<type>/<short-description>` (type matching the commit prefixes; 2-4 kebab-case words) and push under that same name:

```bash
git branch -m <type>/<short-description>        # rename the scratch branch in place
git push -u origin <type>/<short-description>   # local and remote now match
```

**Never push the `worktree-`-prefixed scratch name to origin** — a PR's head branch must be the clean name from the first push (renaming on GitHub after a PR exists closes the PR). Details: [docs/git-workflow.md](docs/git-workflow.md#worktree-scratch-branches).

### Commit Messages

These conventions apply to **all** forms of committing: local commits, PR squash/merge commits, and any other git operations that produce commits.

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

| Prefix     | Usage                                      |
|------------|--------------------------------------------|
| `feat`     | New feature or capability                  |
| `fix`      | Bug fix                                    |
| `refactor` | Code restructuring with no behavior change |
| `docs`     | Documentation only                         |
| `test`     | Adding or updating tests                   |
| `chore`    | Build, CI, tooling, or dependency updates  |
| `style`    | Formatting, whitespace, or cosmetic changes|

Commit messages must reflect the full intent and scope of all changes, not just the last operation performed. Before writing one, review both the conversation context (what the user asked for, the steps taken) and the staged diff holistically. Lead with the primary purpose; secondary details (naming conventions, formatting choices) belong in the body.

The `Co-Authored-By` trailer is automatically appended by Claude Code and should not be duplicated in the commit message body.

### Merging Pull Requests

Squash-merge with the PR title plus number: `gh pr merge <N> --squash --subject "<type>: Title (#N)"`. Do **not** pass `--delete-branch`. Auto-merge is disabled, the head branch must be up-to-date with `main`, three status checks are required, and issue auto-close needs a `Closes #N` keyword per issue in the PR body — the full merge procedure and the post-merge cleanup steps (worktree and plain-checkout variants) are in [docs/git-workflow.md](docs/git-workflow.md#merging-prs). Follow the cleanup steps there after every merge.

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

1. **[ARCHITECTURE.md](ARCHITECTURE.md)** — Read the relevant sections first, then propose specific, targeted updates to reflect the change. Update the directory structure, component map, or design decisions as needed. Do not rewrite the entire file — make surgical edits.

2. **Testing** — For any new public function, type, or component:
   - Write tests following the patterns in [docs/testing.md](docs/testing.md)
   - If tests are deferred, explicitly state what's needed and why it was skipped

3. **CLAUDE.md and docs/** — Update CLAUDE.md only if build commands, the concurrency model summary, or the data flow summary changed. Update the relevant `docs/` guide if testing patterns, review process, or git mechanics changed. Preserve the commit message format and development guidelines as-is.

4. **Maintenance Notes** — At the end of your response, include a summary:

   ### Maintenance Notes
   - ✅ Updated ARCHITECTURE.md directory structure
   - ✅ Added tests for NewComponent
   - ⚠️ No tests yet for `newFunction()` — needs mock for ExternalDependency
   - ✅ CLAUDE.md unchanged (no structural impact)
