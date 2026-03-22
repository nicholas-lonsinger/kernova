# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Design philosophy and UI guidelines are in [SPEC.md](SPEC.md).

## Build & Test

This is an Xcode project (not Swift Package Manager). Build and test via `xcodebuild`:

```bash
# Build
xcodebuild -project Kernova.xcodeproj -scheme Kernova -destination 'platform=macOS' -derivedDataPath DerivedData build

# Run tests
xcodebuild -project Kernova.xcodeproj -scheme Kernova -destination 'platform=macOS' -derivedDataPath DerivedData test

# Run a single test suite
xcodebuild -project Kernova.xcodeproj -scheme Kernova -destination 'platform=macOS' -derivedDataPath DerivedData test -only-testing:KernovaTests/VMConfigurationTests
```

The `-derivedDataPath DerivedData` flag ensures build output goes to a deterministic local `DerivedData/` directory (already gitignored) instead of the per-path-hashed `~/Library/Developer/Xcode/DerivedData/` location. This avoids glob ambiguity when worktrees or parallel builds create multiple DerivedData folders.

Requires **macOS 26 (Tahoe)**, **Xcode 26**, **Swift 6**, and **Apple Silicon** (for macOS guest support). The app uses the `com.apple.security.virtualization` entitlement.

## Architecture

> Full directory structure, component map, data flow diagrams, design decisions, and test coverage details are in [ARCHITECTURE.md](ARCHITECTURE.md). Consult it before making structural changes. The summary below is a quick reference.

Kernova is an AppKit app hosting SwiftUI views that manages virtual machines via Apple's `Virtualization.framework`, supporting macOS and Linux guests.

**Data flow:** `AppDelegate` → `VMLibraryViewModel` → `VMLifecycleCoordinator` → services + SwiftUI views. `MainWindowController` hosts an `NSSplitViewController` with sidebar (`SidebarView`) and detail (`MainDetailView` → `VMDetailView`) panes, plus a native `NSToolbar` with `NSToolbarItem`s. `VMDirectoryWatcher` monitors the VMs directory for external filesystem changes and triggers reconciliation in the view model.

**Concurrency model:** Everything touching `VZVirtualMachine` is `@MainActor`. The codebase uses Swift 6 strict concurrency. Services that interact with VZ are `@MainActor`-isolated; stateless services are `Sendable` structs. Some VZ delegate callbacks use `nonisolated(unsafe)` with `MainActor.assumeIsolated` to bridge back.

**No external dependencies.** The app uses only Apple system frameworks.

## Development Guidelines

### Unit Tests

When adding new functionality or modifying existing behavior, include unit tests for the changes. Follow the existing patterns in `KernovaTests/`:

- Use Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest
- Create mock implementations using protocols (see `KernovaTests/Mocks/`)
- Test models, services, and view models — UI views don't need unit tests
- Test both happy paths and error paths; use error injection in mocks (e.g., setting a `throwError` property)
- Reuse shared test helpers and factories (e.g., `makeInstance()`) rather than duplicating setup logic across test files
- Run the full test suite before committing to ensure nothing is broken

### Logging

The app uses Apple's `os.Logger` (subsystem `com.kernova.app`) with per-component categories. Each service, view model, or model that logs declares a `private static let logger`. When adding or modifying functionality, include log calls at appropriate levels:

| Level | When to use | Persistence |
|-------|-------------|-------------|
| `.debug` | Method entry with parameter snapshots, intermediate states, per-item iteration results. Diagnostic detail only useful when actively investigating. | Discarded unless streaming via Console.app or `log stream` |
| `.info` | General operational context: routine progress, non-critical outcomes, sub-step completion. | In-memory only; evicted under pressure |
| `.notice` | Definitive lifecycle events: VM started/stopped/paused/resumed/saved, bundle created/deleted, app launch. Events you need for post-mortem analysis. | Persisted to disk |
| `.warning` | Unexpected but recoverable situations: missing files, fallback paths taken, degraded operation. | Persisted to disk |
| `.error` | Failures: operations that did not complete, exceptions caught, error states entered. | Persisted to disk |

**Guidelines:**
- Every new service or view model should declare its own `private static let logger = Logger(subsystem: "com.kernova.app", category: "ComponentName")`
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

## Git Workflow

These conventions apply to **all** forms of committing: local commits, PR squash/merge commits, and any other git operations that produce commits.

### Commit Messages

Use the following format for all commits:

```
<type>: <concise subject line>

## Summary
- <bullet points summarizing what changed and why>

## Changes
- <bullet points describing each discrete change>

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

The `Co-Authored-By` trailer is automatically appended by Claude Code and should not be duplicated in the commit message body.

### Merging Pull Requests

When merging PRs with `gh pr merge`, always use `--subject` with the PR title and append the PR number in parentheses (e.g., `"fix: Title (#11)"`), matching the repo's existing convention. Always use `--delete-branch` to clean up the remote branch.

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
