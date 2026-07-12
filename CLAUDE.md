# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Design philosophy and UI guidelines are in [SPEC.md](SPEC.md).
>
> Clipboard subsystem principles (host↔guest copy/paste — the authoritative rules for any clipboard work) are in [CLIPBOARD.md](CLIPBOARD.md).

## Build & Test

This is an Xcode project (not Swift Package Manager). Inside Xcode, use ⌘B / ⌘U as normal. From the terminal, prefer the `Makefile` wrapper:

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

Run `make install-hooks` once after cloning to enable the checked-in `.githooks/`: pre-push runs `make lint` (bypass an individual push with `git push --no-verify`), and post-checkout sets up new worktrees — it copies the gitignored local files listed in `.worktreeinclude` from the main checkout (the definitive list of local files worktrees inherit; Claude Code and other worktree tools consume it natively, the hook makes plain `git worktree add` honor it too — literal paths only, no globs), then runs `make bootstrap`'s derivation if `Config/Local.xcconfig` is still missing — so new git worktrees sign without a manual step (see [Development setup](README.md#development-setup) in the README for the mechanics).

`DEVELOPMENT_TEAM` is not hardcoded in the project — it's derived per-developer from your own signing certificate into the gitignored `Config/Local.xcconfig` by `make bootstrap` (#476, see [Development setup](README.md#development-setup)). `make build`/`make test`/`make test-suite` run it automatically, and the post-checkout hook covers new worktrees; the raw `xcodebuild` form below (and Xcode's own ⌘B/⌘R) assume it has already run, so on a fresh clone (where hooks aren't active yet) run `make bootstrap` once first — otherwise `DEVELOPMENT_TEAM` resolves empty and the Manual/profile-less Debug targets fail to sign.

`make test` is the canonical `xcodebuild` invocation:

```bash
xcodebuild -project Kernova.xcodeproj -scheme Kernova -destination 'platform=macOS' -derivedDataPath DerivedData/Kernova -configuration Debug <build|test>
```

A single `xcodebuild test -scheme Kernova` runs all three test targets (`KernovaTests`, `KernovaMacOSAgentTests`, `KernovaKitTests`) via `Kernova.xctestplan`. This works because `KernovaKit` is referenced as a top-level peer in the project (a `PBXFileReference` in `Kernova.xcodeproj`'s main group) rather than as an `XCLocalSwiftPackageReference` under Package Dependencies. In the dependency form, Xcode treats the package as upstream and hides its `.testTarget`s from the test-plan picker; in the peer form, the package's tests appear in `Edit Scheme → Test → +` as first-class targets and can be added to the test plan. If `KernovaKit` ever needs to be re-added, drag the folder into the Project Navigator from Finder rather than using `Add Package Dependencies → Add Local`. `make test-package` exists as a focused shortcut for iterating on package tests in isolation.

The `-derivedDataPath DerivedData/Kernova` flag ensures build output goes to a deterministic local directory (the whole `DerivedData/` tree is already gitignored) instead of the per-path-hashed `~/Library/Developer/Xcode/DerivedData/` location. This avoids glob ambiguity when worktrees or parallel builds create multiple DerivedData folders. The path is nested one level because Xcode's Settings → Locations → Derived Data *Relative* mode nests a per-project subfolder rather than writing straight into the folder you point it at (`DerivedData/Kernova/`, not `DerivedData/`, whichever scheme is built) — targeting that same nested path means a terminal build and a Relative-mode Xcode build land their products in one shared build dir instead of two divergent copies. `make clean` removes the whole `DerivedData/` root, clearing both.

Sharing *incremental build state*, not just the output location, requires omitting the flag: `-derivedDataPath` records a different build-arena identity than the IDE's Relative setting even when the resolved path is identical, so with the flag every CLI↔GUI switch re-runs the entire compile graph in both directions (measured: all object files rewritten each way). A flag-less `xcodebuild` reads the same IDE preference and computes the same arena as the GUI, making switches in either direction second-scale null builds. The Makefile therefore omits `-derivedDataPath` automatically when this machine's Xcode is set to *Relative* and the workspace has no per-user derived-data override (Xcode's File → Project Settings…), and passes the explicit flag otherwise — CI and machines on Xcode's default hashed location keep deterministic in-worktree output at the cost of not sharing with a GUI they don't use. The canonical invocation above shows the explicit-flag form since it's the one that works everywhere. (Committing the setting in `xcshareddata/WorkspaceSettings.xcsettings` doesn't work — Xcode only honors derived-data location from the global preference or the per-user `xcuserdata` workspace settings, both uncommittable.)

### Build version

`CFBundleVersion` is **squash-merge aware**. Instead of `git rev-list --count HEAD` (which climbs by one per branch commit and then collapses back down at squash-merge), it reports the commit count the branch *will* have once its PR squash-merges into `main`: `git merge-base HEAD origin/main` gives the branch point (after the rebase git forces before merge, that's `origin/main`'s tip), and the number is `rev-list --count <base>` plus one when the checkout carries work not yet on `main` — a commit beyond the base **or** an uncommitted change (a dirty tree is the in-progress next commit; untracked non-ignored files count, gitignored build output does not). The only `+0` case is a clean checkout of a commit already on `main`. Commits and dirt still collapse to a single squash commit, so the delta never exceeds `+1`. A feature branch therefore reads its post-merge number and **holds it steady** across its own commits; rebasing onto an advanced `main` moves the base forward and re-derives the number (the mandatory rebase is the trigger, not a per-commit creep). On `main` with a clean tree the value equals the old total commit count — what ships (archived from `main`, per [RELEASING.md](RELEASING.md)) is unchanged. If `origin/main`/history is absent — a CI shallow clone (`fetch-depth: 1`), which never archives — it falls back to the legacy `rev-list --count HEAD`.

A single **`Tools/set-build-number.sh <app|agent>`** owns this logic; every target's `Set Build Number from Git` build phase calls it (it replaced five byte-identical inline copies). It writes `#define KERNOVA_BUILD_NUMBER N` (app mode) or `#define AGENT_BUILD_NUMBER N` (agent mode) into `DERIVED_FILE_DIR`, and the source `Info.plist` references the symbol directly (`<string>KERNOVA_BUILD_NUMBER</string>`), substituted via `INFOPLIST_PREPROCESS` inside `ProcessInfoPlistFile` so build-graph reordering can't clobber it. **App mode** (unscoped) serves the `Kernova` app, the `KernovaQuickLook` extension, and the host `KernovaFileProvider` extension, so the two embedded appexes always match their host app's version. **Agent mode** scopes both the count *and* the squash `+1` to `KernovaGuestAgent/ KernovaMacOSAgent/` (both the pre- and post-rename directory paths, so the count stays monotonic across the rename, and a branch that doesn't touch the agent sources leaves its number unchanged); it serves `KernovaMacOSAgent` and its embedded `KernovaMacOSAgentFileProvider`. When adding a new top-level target that needs a dynamic build number, call the shared script with the appropriate mode instead of patching the built `Info.plist` after the fact.

Requires the toolchain listed under [Requirements](README.md#requirements) in the README. The app is Apple Silicon-only (`ARCHS = arm64` at the project level) — Virtualization.framework's macOS-guest and save/restore APIs don't exist on x86_64, and macOS 26 is the last Intel release, so no Intel slice is built and `#if arch(arm64)` guards are unnecessary. The app uses the `com.apple.security.virtualization` entitlement.

## Architecture

> Full directory structure, component map, data flow diagrams, design decisions, and test coverage details are in [ARCHITECTURE.md](ARCHITECTURE.md). Consult it before making structural changes. The summary below is a quick reference; if it conflicts with ARCHITECTURE.md, ARCHITECTURE.md is authoritative.

Kernova is a pure-AppKit app that manages virtual machines via Apple's `Virtualization.framework`, supporting macOS and Linux guests.

**Data flow:** `AppDelegate` → `VMLibraryViewModel` → `VMLifecycleCoordinator` → services + AppKit view controllers. `MainWindowController` hosts an `NSSplitViewController` with sidebar (`SidebarViewController`, a pure-AppKit source-list `NSOutlineView`) and detail (`DetailContainerViewController`) panes, plus a native `NSToolbar` with `NSToolbarItem`s. The detail pane layers a pure-AppKit `VMDisplayBackingView` (for `VZVirtualMachineView`) over the AppKit detail content — an empty-state view or `VMDetailRouterViewController`, which routes by VM status to `VMSettingsViewController`, a status placeholder, the macOS install progress VC, or the display placeholder. Lifecycle confirmation alerts are presented by `DetailAlertsPresenter`. `VMDirectoryWatcher` monitors the VMs directory for external filesystem changes and triggers reconciliation in the view model.

**Concurrency model:** Everything touching `VZVirtualMachine` is `@MainActor`. The codebase uses Swift 6 strict concurrency. Services that interact with VZ are `@MainActor`-isolated; stateless services are `Sendable` structs. Some VZ delegate callbacks use `nonisolated(unsafe)` with `MainActor.assumeIsolated` to bridge back.

**No third-party dependencies.** The Kernova app target uses only Apple system frameworks. Apple-published Swift Packages (e.g. `apple/swift-protobuf`, currently consumed by the local `KernovaKit/` package) are acceptable when they pull their weight; non-Apple packages still require explicit sign-off.

## Mac App Store Readiness

Kernova is intended for **Mac App Store distribution**, and the main app **runs under the App Sandbox** in every build configuration (#89). `Kernova/Resources/Kernova.entitlements` carries `com.apple.security.app-sandbox`, `com.apple.security.network.client` (sole network use: `IPSWService` restore-image downloads from Apple's CDN), `com.apple.security.files.user-selected.read-write` (open/save-panel grants), `com.apple.security.files.downloads.read-write` (the fixed IPSW download destination and its `.kernovadownload` resume sidecar in `~/Downloads`), `com.apple.security.files.bookmarks.app-scope` (persisting panel grants across launches), `com.apple.security.virtualization`, `com.apple.security.device.audio-input`, and a **per-build-configuration** `com.apple.security.application-groups` driven by the `KERNOVA_APP_GROUP` build setting (added for the host "Copy to Mac" File Provider's shared staging container, #424). **Debug** uses a Team-ID-prefixed group (`$(DEVELOPMENT_TEAM).app.kernova`) that macOS grants silent container access to with no provisioning profile (macOS 15 app-group protection, criterion C) — so the project clones-and-runs for anyone signing with their own team, and the guest agent + guest File Provider never hit the "access data from other apps" consent prompt inside an unregistered guest VM. `DEVELOPMENT_TEAM` itself is not hardcoded: it's derived from each developer's own signing certificate by `make bootstrap` (`Tools/bootstrap-team.sh`) into a gitignored `Config/Local.xcconfig`, included by the tracked `Config/Base.xcconfig` (#476) — `make build`/`make test` run it automatically. The same per-developer team also backs the host↔File-Provider-extension XPC peer pin (`KernovaKit`'s `FileProviderConfig.host()`, via `KernovaCodeSignature.teamIdentifier()`), so that peer validation is correct for whichever team built the app rather than pinned to a single hardcoded team. **Release** uses the canonical iOS-style `group.app.kernova` Apple recommends on macOS and requires for developer-portal registration (#463), authorized by an embedded provisioning profile. Signing splits by target in Release: the **guest agent** (`KernovaMacOSAgent`) and its **File Provider extension** sign **Manual** with a `Developer ID Application` identity and manually-created Developer ID profiles (`Kernova macOS Agent Developer ID` / `Kernova macOS Agent File Provider Developer ID`) carrying the `group.app.kernova` App Groups authorization, plus `OTHER_CODE_SIGN_FLAGS = --timestamp` — because the agent is packaged into `Resources/KernovaMacOSAgent.dmg` at *build* time and Xcode's export-time Developer ID re-signing can't reach inside a DMG resource, so the agent must already carry its final distribution signature (Developer ID + hardened runtime + timestamp) when the DMG is baked. A Developer ID profile isn't device-locked, so the agent and its guest File Provider validate inside an unregistered guest VM — whereas a device-locked *Development* profile would be refused launch outright by `fileproviderd`, failing device validation before any app-group check (so no "access data from other apps" consent prompt is ever reached). The **host app** and the **host File Provider** sign `Automatic`/Apple Development at build time (with `REGISTER_APP_GROUPS = YES` so Xcode 16.3+ automatic signing generates Developer ID profiles carrying the app group) and pick up their Developer ID signature at Organizer export. The end-to-end release + notarization flow is documented in [RELEASING.md](RELEASING.md). Each executable resolves its value at runtime from a `KernovaAppGroup` Info.plist key via KernovaKit's `KernovaAppGroup.identifier()` (the package can't read Xcode build settings). Host↔extension addressing is `NSFileProviderServicing`, #460, not an app-group Mach service; both forms are MAS-compatible (Release ships `group.`). The virtualization entitlement is MAS-compatible alongside the sandbox (UTM ships exactly this combination on the store, macOS guests included). Host vsock needs no network entitlement: the app never calls `socket()`/`bind()`/`listen()` itself — `VZVirtioSocketListener`/`VZVirtioSocketConnection` hand it already-connected fds, and the sandbox's network entitlements gate socket-*acquisition* syscalls, not I/O on granted fds. The serial relay's `AF_UNIX` listener binds inside the app's own temp directory (file-rule-mediated), so `network.server` is deliberately absent. The only executable the app spawns is its own bundled `KernovaRelaunchHelper`, sandboxed with `app-sandbox` + `inherit`.

**Launch model — the app is an ordinary resident menu-bar app.** #460 dropped the launchd LaunchAgent model (no `app.kernova.plist`, no `--background`/launcher/agent split, no Mach service). The single binary is either the resident app or, under XCTest, a plain foreground test host (keyed on `isTestHost`). It launches headless (`.accessory`), keeps VMs running when the GUI closes, and shows its window on a manual launch but not a login launch — classified deterministically from the launch Apple event's `keyAELaunchedAsLogInItem` property (legacy-documented; no modern purpose-built API exists, FB10207829), falling back to a cold-launch activation heuristic when the event is unreadable. **"Open at Login" is opt-in** — a General-settings toggle over `SMAppService.mainApp` (`LoginItemService`), not an always-on agent. File Provider host↔extension IPC uses the canonical `NSFileProviderServicing` anonymous-XPC pattern (the owner connects and exports the relay; the extension calls back at `fetchContents`; a Darwin notification is the reconnect doorbell) — no Mach service and no broker. Both `SMAppService.mainApp` and the servicing pattern are MAS- and sandbox-compatible; the sandbox flip (#89) kept the XPC pattern intact, though the owner's servicing *entry call* had to become identifier-based (`NSFileProviderManager.getService(named:for:)`) and the domain-root readdir security-scoped, because the sandboxed app has no filesystem access to `~/Library/CloudStorage` (#539).

**Sandbox rules for new code** (the sandbox is on for every build configuration — write code that lives within it):

- **User-picked files persist their grant as an app-scoped security bookmark** stored next to the raw path (`SecurityScopedBookmark.capture` at the panel pick site; see `StorageDisk.bookmark` and friends). Access sites resolve through the RAII `ScopedAccess`: VM-runtime scopes are owned by `VMInstance.runtimeFileAccess` (`RuntimeFileAccess`), opened by `openRuntimeFileAccess()` per boot attempt (which also heals stale bookmarks and moved paths) and released exactly once in `tearDownSession()`; momentary probes (existence checks, trashing) open and release a `ScopedAccess` locally. A `nil`/dead bookmark falls through to the raw-path attempt, which under the sandbox surfaces the *existing* missing-file UX (start-time not-found errors, the settings warning icon) and re-picking mints a fresh bookmark — **never add special-case handling for pre-sandbox data** (no decode-time migrations, no `Container Migration.plist`; users move their VMs via the documented drag-and-drop import).
- **App-internal state belongs in the container.** `.applicationSupportDirectory` (the VM library), `FileManager.temporaryDirectory`, and the app-group container all resolve correctly under the sandbox. Never build paths off `homeDirectoryForCurrentUser` expecting the *real* home — in a sandboxed app it is the container home (ask the system for the folder instead, e.g. `.downloadsDirectory`).
- **Prefer in-process Apple framework APIs over shelling out** to system command-line tools (`Process` / `NSTask` → `/usr/bin/ditto`, `unzip`, `tar`, …), which a sandboxed app cannot usefully spawn, and over adding entitlements unavailable to MAS apps. (This is also why VM disks are created by decompressing bundled ASIF templates — macOS 26 has no public in-process ASIF-creation API, and `diskutil` is unreachable from the sandbox.)

## Development Guidelines

### Unit Tests

When adding new functionality or modifying existing behavior, include unit tests for the changes. Follow the existing patterns in `KernovaTests/`:

- Use Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest
- Create mock implementations using protocols (see `KernovaTests/Mocks/`)
- Test models, services, and view models — UI views don't need unit tests
- Test both happy paths and error paths; use error injection in mocks (e.g., setting a `throwError` property)
- Reuse shared test helpers and factories (e.g., `makeInstance()`) rather than duplicating setup logic across test files
- Run the full test suite before committing to ensure nothing is broken

#### Async waits in tests

macos-26 CI runners have heavy `@MainActor` scheduling jitter. With a `waitUntil`/`pollUntil` poll loop, the timeout deadline *is* the pass/fail criterion — so a starved scheduler fails a test whose condition would have become true. **When a test waits for async state that has an underlying signal, make the wait event-driven from the start — do not reach for a poll loop.** With event-driven waits the timeout is only a stuck-condition backstop the happy path never reaches.

Pick the seam by what produces the state. `AsyncGate`/`waitUntil`/`TestFailure` live in the shared `KernovaTestSupport` SwiftPM product (`KernovaKit/Sources/KernovaTestSupport/`), imported by all three test targets; `waitForChange` is KernovaTests-only and stays in `KernovaTests/TestHelpers.swift`:

| Seam | Use when | Notes |
|------|----------|-------|
| `waitForChange(until:)` | The predicate reads a production `@Observable` property directly (e.g. `service.clipboardContent`, `service.agentStatus`) | KernovaTests only. Built on `withObservationTracking`: the predicate must be side-effect-free and read every inspected value through an `@Observable` getter on the arming pass, or only the deadline wakes it. |
| `AsyncGate` (`notify()` + `wait(until:)`) | The signal flows through a test-owned double/recorder | Call `notify()` after each relevant mutation. A single implementation serves every bundle: `wait`/`waitUntil` take the caller's isolation via `isolation: isolated (any Actor)? = #isolation`, so the same code runs isolation-free for `@MainActor` KernovaTests predicates and nonisolated GuestAgent/KernovaKit predicates alike — no per-bundle fork to keep in sync (#526). |
| `await` the production `Task` | A production `Task` does the work | Expose it via a `#if DEBUG …ForTesting` seam and `await task.value` instead of polling the flag it flips. |

If the condition is driven by a *single* event a starved scheduler can miss (e.g. one heartbeat that latches a terminal state), drive it *continuously* — a wait conversion alone won't fix that.

Polling (`waitUntil` / `pollUntil`) is acceptable **only** for a genuine no-signal predicate: a negative assertion ("prove nothing arrived"), a filesystem-appearance poll, or an exception-catch predicate. There, use a generous cadence, assert end-state not per-iteration, and add a `RATIONALE:` comment so reviews don't re-flag it.

**Injected production timeouts race the test body — never pick a small "tidy" value.** Event-driven waits fix the *observation* side, but a test that passes a shortened production timeout into the code under test (to bound a lingering background timer, or just because the default felt long) adds a *second* clock racing the test's own progress. If that timer firing mutates observable state, and it can fire before the test reaches the line that depends on the pre-timeout state, a starved CI scheduler loses the race and the test fails non-deterministically — even with perfect event-driven waits. So an injected production timeout must be **either** (a) the behavior under test — the test is *waiting for* it to fire, where a small value is correct (e.g. `connectTimeout: 0.05` in `connectTimeoutFailsPendingPullWithServerUnreachable`) — **or** (b) sized past any plausible scheduler stall: use the production default, or ≥60s. A lingering dispatch timer in a test process is a no-op that does not delay suite completion, so shrinking it to "keep the linger short" buys nothing and costs a flake. Canonical bug: `FileProviderServiceSourceTests.cancelDispatchedPullAsksOwnerToAbort` once passed `fetchReplyTimeout: 2` to bound a harmless post-`cancel()` timer; on a stalled runner that reply timer fired *before* `cancel()`, replacing the expected `NSUserCancelledError` with `serverUnreachable`.

#### Test-only seams

When a test needs to observe state that is `private` in production, pick the tightest exposure that still works:

1. **`private(set) var x`** — internal getter, private setter. The idiomatic choice when production code reading the state is harmless; tests reach it via `@testable import`, no extra accessor needed.
2. **`#if DEBUG`-gated read accessor** — when the state is a test-only implementation detail that production code should *not* read. Keep the field `private` and add a `…ForTesting` computed getter wrapped in `#if DEBUG`, so the seam is physically absent from Release builds and test-only access becomes a compile-time guarantee rather than a naming convention. Place `#if DEBUG` before the doc comment and `#endif` after the accessor.

`AttachmentFileMonitor.watchedParentsForTesting` is the canonical example; the `…ForTesting` accessors in `VsockClipboardService` and `VsockGuestClipboardAgent` follow the same pattern. Because this rationale is shared, the gate itself is the documentation — don't repeat a "DEBUG-only so it can't leak" note at each site.

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

#### The severity bar — Dismiss and Annotate are real options

A finding earns **Fix now** or **Fix later** only if **both** hold:

1. **Reachable** — a user doing normal things (or a supported automated flow) can actually hit it.
2. **Consequential** — the outcome is worse than a transient cosmetic glitch, a logged self-recovering retry, or a state an obvious user action recovers from.

Findings with these signatures default to **Dismiss** (or **Annotate** with `RATIONALE:` when the code would otherwise be re-flagged every review):

- **Hypothetical future code** — "a future caller/method could bypass X." Unwritten code can't be defended against with access control; document the invariant where it lives instead.
- **Adversarial scheduling** — races requiring timing no real user/system flow produces, with a bounded, benign outcome (e.g. one spurious retry). If unsure whether the flow can produce it, that investigation is the triage — do it before filing, not after.
- **Degenerate inputs** — inputs no real workflow produces (e.g. same-name-differing-only-by-case bundles dropped together), failing recoverably.
- **Pre-existing behavior surfaced by an unrelated diff** — verify against the merge base before attributing: it's a finding against *this* change only if the change introduced or worsened it. Otherwise it's at most a new issue on its own merits, judged by the same bar — not part of this review's loop.

**Stop-the-chain rule:** when a finding is about the *fix for a previous review finding* and severity is declining across the chain (#487 → #490 → #492 → #493 is the canonical example — ending at "`private` doesn't stop a hypothetical future method in the same class"), do not file the next link. Dismiss or Annotate. A review that has moved from defects in the code to meta-findings about prior fixes has run out of real defects.

**Matching review effort to the diff:** `/code-review low` for trivial/mechanical diffs; `medium` (precision-biased — "findings a maintainer would act on") as the default for bug fixes; `high`/`xhigh` (recall-biased — "err on the side of surfacing", uncertain findings expected by design) for features, redesigns, and the clipboard/File-Provider/vsock subsystems where theoretical races are often real. Findings from recall-biased runs especially must clear the severity bar above before being filed.

#### Review Debt Tracking

Valid findings that are **out of scope** for the current task must be captured as GitHub issues rather than silently dropped.

**What to capture** (important + moderate severity, and clearing [the severity bar](#the-severity-bar--dismiss-and-annotate-are-real-options) above):
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
| `review-debt/dead-code` | Dead code surfaced by the Periphery scan (applied automatically by `dead-code.yml`; use for manually-filed dead-code findings too) |

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
git push origin HEAD:<type>/<short-description>      # every later push: same refspec (add -f after a rebase)
```

The local↔remote name mismatch is deliberate: the local `worktree-` branch is a
throwaway that `ExitWorktree` deletes on exit, so only the remote name — the one
humans and GitHub see — has to be clean. The cost of the mismatch is that
**every push must spell the refspec**: with `push.default` unset (git's default
is `simple`) and the local/remote names differing, a bare `git push` refuses to
push — depending on git version/config it fails loudly (`fatal: The upstream
branch of your current branch does not match…`) or prints only an easy-to-miss
hint, but either way nothing is pushed. The `-u`
on the first push doesn't change that; it exists so `git status -sb` tracks the
remote branch. So push with `git push origin HEAD:<type>/<short-description>`
every time (add `-f` after a rebase), pass `--head <type>/<short-description>`
to `gh pr create`, and verify after each push with `git status -sb` — no
`[ahead N]` means the push landed.
**Always push before exiting the worktree** so the work is safe on origin:
`ExitWorktree(remove)` discards the local commit, and it drops *unpushed* commits
silently.

**Never push the `worktree-`-prefixed scratch name to origin** — that means no
bare `git push -u origin HEAD` on the first push; always name the clean remote
ref in the refspec. A PR's head branch must always be the clean
`<type>/<short-description>` name. (Renaming a branch on GitHub *after* a PR
exists does not retarget the PR — it closes it — so name it correctly at first
push.)

### Worktree LaunchServices cleanup

Every worktree build registers its app bundles (and their embedded appexes)
with LaunchServices; when the worktree is removed those registrations become
ghosts — stale entries that accumulate and have previously hijacked UTI and
name resolution. Dead-path ghosts self-heal lazily: the `post-checkout` git
hook's step 3 runs `Tools/ghosts.sh --sweep-ls` on every *initial* checkout
(`git worktree add` passes the null ref as `$1`; a plain `git switch` never
pays the multi-second `lsregister` dump), unregistering every registered
`app.kernova.*` path that no longer exists on disk (`lsregister -u` works
even after the path is gone). The sweep only heals dead paths; LIVE stray
copies still need the on-demand tools: `make ghosts` (report) /
`make clean-ghosts` (also unregisters/kills/prunes) and `make ls-reset` for
the legacy pre-#471-rename `com.kernova.app` identifier a plain regex update
to `ghosts.sh` doesn't yet cover (`Tools/ghosts.sh`, `Tools/ls-reset.sh`,
#454). `make ghosts` also
inventories LIVE Kernova.app copies still on disk under Trash and
`~/Library/Developer/Xcode/DerivedData` — exactly the hashed-DerivedData case
above — and flags any that outrank the installed `/Applications` copy in the
LaunchServices/PluginKit CFBundleVersion election, since Spotlight indexes
neither location (`mdfind` alone misses them). Do not reach for a system-wide
`lsregister -kill -r` rebuild: `-kill` has been removed from current macOS's
`lsregister` ("dangerous and no longer useful" per `lsregister -h`), and a
plain `lsregister -u <path>` reliably unregisters an entry even once its path
is gone (verified empirically 2026-07-08, `Tools/ls-reset.sh`).

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

End every commit message with a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer — no model name. It is **not** appended automatically — add it explicitly (e.g. `git commit --trailer "Co-Authored-By: Claude <noreply@anthropic.com>"`). Include it exactly once; do not duplicate it in the message body.

### Merging Pull Requests

When merging PRs with `gh pr merge`, always squash-merge with `--squash --subject` using the PR title and appending the PR number in parentheses (e.g., `--squash --subject "fix: Title (#11)"`), matching the repo's existing convention.

**Do not use `--delete-branch`.** The repo has `delete_branch_on_merge` enabled on GitHub, so remote branches are auto-deleted. The `--delete-branch` flag causes `gh` to run `git checkout main` locally, which fails in worktree contexts.

**Linking issues for auto-close:** When a PR resolves GitHub issues, include `Closes #N` (or `Fixes #N`) in the PR body — not just a table reference like `| #N |`. GitHub only auto-closes an issue when the merge commit or PR body has the keyword `closes`, `fixes`, or `resolves` immediately before its `#N`, **repeated for each issue**: `Closes #12, closes #34, closes #56` (or one `Closes #N` per line).

#### Post-merge cleanup

After a successful merge, confirm it landed, then sync `main` (and, when working directly in a checkout, tear down the local branch):

1. `gh pr view <N> --json state -q .state` — confirm `"MERGED"` before deleting anything.

**In an `EnterWorktree` session** (the usual case), **stay in the worktree** — do not `ExitWorktree`. Just fast-forward the primary checkout's `main` from inside the worktree:

2. `git -C <primary-checkout-path> pull --prune --ff-only` — `git -C <path>` runs this one command as if in the primary checkout (where `main` is checked out), so it fetches, fast-forwards `main` onto the squash commit, and drops the now-stale `origin/<type>/<short-description>` remote-tracking ref — all without leaving the worktree. A plain `git fetch --prune` from inside the worktree would only update the shared `origin/main` ref, not the local `main` branch pointer, which is why this targets the primary checkout. (For this repo the primary is `/Users/nlonsinger/Developer/GitHub/nicholas-lonsinger/kernova`; resolve it at runtime via `git worktree list` if unsure.) The worktree and its scratch branch are left in place for continued or follow-up work.

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
