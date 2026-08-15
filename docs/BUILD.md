# BUILD.md

Read the relevant section before touching build machinery — hooks and worktree setup, the signing identity, test-target topology, DerivedData, build numbers, guest-agent versioning, or LaunchServices cleanup. None of it is needed for a routine `make build` / `make test`; fresh-clone setup is in the [README](../README.md#development-setup).

## Git hooks and worktree setup

`make install-hooks` enables the checked-in `.githooks/`.

**pre-push** runs `make lint`. Bypass an individual push with `git push --no-verify`.

**post-checkout** sets up a new worktree with no manual step: it copies the gitignored local files listed in `.worktreeinclude` from the main checkout, then sweeps LaunchServices ghosts (below).

`.worktreeinclude` is the definitive list of local files a worktree inherits. Claude Code and other worktree tools read it natively; the hook is what makes a plain `git worktree add` honor it too. **Literal paths only — no globs.**

## Signing identity

Debug signs ad-hoc by default — `Config/Base.xcconfig` sets `CODE_SIGN_IDENTITY = -` — so a fresh clone builds with no Apple account, team, or certificate. The gitignored, hand-maintained `Config/Local.xcconfig`, included by that file and templated by `Config/Local.xcconfig.example`, overrides both that and `DEVELOPMENT_TEAM`. Worktrees inherit it through `.worktreeinclude`.

Set `CODE_SIGN_IDENTITY = Apple Development` there whenever you have a certificate. TCC keys each privacy grant to the app's designated requirement: under a real identity that is `identifier "app.kernova" and anchor apple generic and certificate leaf[subject.CN] = …`, stable across rebuilds, while an ad-hoc signature's is a bare `cdhash`. Every rebuild is then a new app to TCC, and a grant like the Downloads folder re-prompts instead of sticking.

`DEVELOPMENT_TEAM` is what automatic signing resolves that certificate through, and the guest agent's Release Developer ID signing needs it too ([RELEASING.md](RELEASING.md)) — keep the two lines together.

The guest agent and `KernovaRelaunchHelper` pin their Release identities at target level, which outranks a project xcconfig; the app and both test bundles leave Release unpinned, so the override reaches them too — an entitled archive needs the real identity, and a team-signed, hardened test host rejects an ad-hoc test bundle under library validation, so host and bundle must sign together.
The guest agent stays ad-hoc in Debug as well: it runs inside the guest, where a host code identity buys nothing.

The app's entitlements resolve through the same override point. `com.apple.vm.networking` is restricted — automatic signing refuses to sign it without an authorizing profile, and amfid kills an ad-hoc-signed binary that claims it at exec ("adhoc signed but contains restricted entitlements") — so the app's `CODE_SIGN_ENTITLEMENTS` resolves through `KERNOVA_APP_ENTITLEMENTS` in both configurations, defaulting in `Base.xcconfig` to `Kernova/Resources/Kernova.Development.entitlements`: the shipping set minus that key, keeping a profile-less checkout building and launchable.

With the capability enabled on the team's App ID, setting `KERNOVA_APP_ENTITLEMENTS = Kernova/Resources/Kernova.entitlements` in `Local.xcconfig` opts the app into the full set — automatic signing then embeds the authorizing Xcode-managed profile, and an archive cut this way carries the key ([RELEASING.md](RELEASING.md) owns the per-lane choice). Code asks which set it was signed with through `EntitlementService`, never `#if DEBUG`.

## One test invocation, three test targets

A single `xcodebuild test -scheme Kernova` runs `KernovaTests`, `KernovaMacOSAgentTests`, and `KernovaKitTests` through `Kernova.xctestplan`.

That works because `KernovaKit` is referenced as a top-level peer — a `PBXFileReference` in `Kernova.xcodeproj`'s main group — rather than as an `XCLocalSwiftPackageReference` under Package Dependencies. In the dependency form Xcode treats the package as upstream and hides its `.testTarget`s from the test-plan picker; in the peer form they appear in `Edit Scheme → Test → +` as first-class targets that can be added to the plan.

**If `KernovaKit` ever has to be re-added, drag the folder into the Project Navigator from Finder — not `Add Package Dependencies → Add Local`.**

`make test-package` is a focused shortcut for iterating on the package tests alone.

## CI

Three of the workflows in `.github/workflows/` are required status checks: `lint`, `build-and-test`, and `proto-drift`. The "Required actions" ruleset matches them **by job name**, and that ruleset lives in GitHub's settings rather than in this repo — so renaming a job means editing the ruleset in the same change, or every PR waits on a check that never reports.

The `lint` job runs `make lint`, which is therefore what gates a merge: `swift-format --strict`, shell (`bash -n` plus shellcheck, which it treats as required once `$CI` is set), `Tools/check-docs.sh` for the documentation line cap and link validity, and `Tools/check-entitlements.sh` for key parity between the two app entitlement variants. Each workflow's own header explains its trigger design; read it there before changing one.

`Kernova.xctestplan` sets `retryOnFailure` with two repetitions, so a test that fails once and passes on the retry still greens the job. The "Report flaky (retried) tests" step reads the result bundle and names those tests, which is where to look — a green conclusion on its own says nothing about flakes.

The dead-code scan runs on a schedule and on demand with `gh workflow run dead-code.yml`. Periphery is configured in `.periphery.yml` for that job and is not installed locally.

## Derived data and build arenas

On a dev machine `make build`/`make test` omit `-derivedDataPath` entirely. A flag-less `xcodebuild` reads the machine's Xcode derived-data preference (Settings → Locations) and computes the same build arena the GUI does — same location *and* same arena identity — so terminal and Xcode builds share incremental state and switching between them is a second-scale null build.

That holds in every preference mode: Xcode's default per-path-hashed `~/Library/Developer/Xcode/DerivedData/Kernova-<hash>`, *Relative* (`DerivedData/Kernova/` inside the checkout), and a per-user workspace override. Kernova adapts to whatever the machine is set to rather than prescribing a setting — and the setting cannot be committed anyway: Xcode honors the location only from the global preference or the per-user `xcuserdata` workspace settings, never from `xcshareddata/WorkspaceSettings.xcsettings`.

**Omitting the flag is load-bearing.** Passing `-derivedDataPath`, even pointed at the identical resolved path, records a different build-arena identity in the build description, and every CLI↔GUI switch then re-runs the entire compile graph in both directions (measured in Relative mode: all object files rewritten each way).

Only CI keeps the explicit `-derivedDataPath DerivedData/Kernova` — the Makefile passes it when `$CI` is set and the workflows mirror it by hand. There is no GUI to share with there, and a deterministic in-worktree path keeps artifact handling simple. The path nests one level to match how Relative mode nests a per-project subfolder, so the flag form and a Relative-mode build agree on layout.

### Resolving an arena

`Tools/derived-data-path.sh` mirrors Xcode's decision tree for tooling that needs the concrete location: default → hashed `~/Library` folder; relative → nested in-checkout folder; absolute custom → hashed under the custom root; per-user workspace override → defer to `xcodebuild -showBuildSettings`.

The default-mode folder hash is a pure function of the `.xcodeproj` path — MD5 the path's UTF-8 bytes, split the digest into two big-endian 64-bit halves, render each half as 14 base-26 letters (`a`–`z`) most-significant first — verified against every live arena's recorded `info.plist` `WorkspacePath`. Because it needs only the path *string*, a torn-down worktree's arena stays locatable after the worktree is gone.

`Tools/arena-label.sh` runs that mapping backwards for display: given an arena, or any path inside one, it reads the recorded `WorkspacePath` and prints the checkout it belongs to. That is why `make ghosts` and `make doctor` never print a bare `Kernova-<hash>` a reader would have to resolve by hand.

`make clean` removes both the in-worktree `DerivedData/` and the resolved arena, through `Tools/ghosts.sh --evict`. **Never `rm -rf` an arena directly** — eviction unregisters the bundles inside it first, and a bare delete strands Launch Services registrations pointing into the hole, generating the very ghosts `make clean-ghosts` then has to sweep. Eviction also refuses an arena a running app is executing from.

## Build version

`CFBundleVersion` is **squash-merge aware**. `git rev-list --count HEAD` would climb by one per branch commit and collapse back down at squash-merge; instead the number reported is the commit count the branch *will* have once its PR squash-merges into `main`.

`git merge-base HEAD origin/main` gives the branch point — after the rebase git forces before merge, that is `origin/main`'s tip — and the number is `rev-list --count <base>` plus one when the checkout carries work not yet on `main`: a commit beyond the base **or** an uncommitted change (a dirty tree is the in-progress next commit; untracked non-ignored files count, gitignored build output does not).

A clean checkout of a commit already on `main` is the only `+0` case, and since commits and dirt collapse into one squash commit the delta never exceeds `+1`.

A feature branch therefore reads its post-merge number and holds it steady across its own commits; rebasing onto an advanced `main` moves the base forward and re-derives it. On `main` with a clean tree the value equals the old total commit count, so what ships is unchanged. With `origin/main` or history absent — a CI shallow clone, which never archives — it falls back to `rev-list --count HEAD`.

`Tools/set-build-number.sh <app|agent>` owns this logic, and every target's `Set Build Number from Git` build phase calls it. It writes `#define KERNOVA_BUILD_NUMBER N` (app mode) or `#define AGENT_BUILD_NUMBER N` (agent mode) into `DERIVED_FILE_DIR`; the source `Info.plist` references the symbol directly, substituted via `INFOPLIST_PREPROCESS` inside `ProcessInfoPlistFile` so build-graph reordering cannot clobber it.

**App mode** serves the `Kernova` app. **Agent mode** serves `KernovaMacOSAgent`, and scopes both the count and the squash `+1` to `KernovaGuestAgent/ KernovaMacOSAgent/` — both path spellings, so the count stays monotonic across the directory rename and a branch that doesn't touch agent sources leaves its number unchanged.

## Guest agent versioning

The guest agent has its **own** `MARKETING_VERSION`, independent of the app's. Bump it whenever a change means a running guest needs the agent reinstalled: the version mismatch is what surfaces the "update the guest agent" affordance on the host, so an unbumped behavioral change ships silently to nobody.

Bump it in the same PR as the behavior change, even mid-PR. The first behavioral change on a branch bumps the **minor**; later revisions on that branch bump the **patch**.

The value is set in **two** places — the Debug and Release configurations of the `KernovaMacOSAgent` target — and both must move together.

Two parallel PRs that both picked the same next version rebase-merge cleanly, since the setting lines are identical; the later one must then manually advance the version again before merging.

## Low-overhead Run scheme

`Kernova (No Debugger)` is a second shared scheme for interactive Xcode use when the attached debugger's own overhead is the thing under test — clipboard and vsock throughput work. The post-#714 file paths are I/O-bound and move the same with and without an attached debugger ([docs/research/2026-08-14-post-714-pipeline-baseline.md](research/2026-08-14-post-714-pipeline-baseline.md)); the scheme matters when the stage under test is CPU-bound or being profiled.

It builds the same Debug configuration as `Kernova` — same `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`, `-Onone`, `ENABLE_TESTABILITY` — but its `LaunchAction` attaches no debugger (`selectedDebuggerIdentifier=""`, `Xcode.IDEFoundation.Launcher.PosixSpawn` in place of LLDB), so Run launches via `posix_spawn` the way a command-line build does.

Main Thread Checker and Thread Performance Checker are disabled explicitly in the scheme's XML (`disableMainThreadChecker`, `disablePerformanceAntipatternChecker`), so they stay off even if a future edit re-attaches the debugger here. Queue Debugging's "Enable backtrace recording" has no scheme attribute at all — don't hunt for one. It is off by default and, unlike the other two, is only ever injected alongside a debugger attach via `libBacktraceRecording.dylib`, so dropping the attach is what suppresses it.

The tradeoff is no LLDB session on this scheme: no breakpoints, no variable inspection, no pause-on-crash — switch back to plain `Kernova` for a normal debugging session. A Debug build still carries `get-task-allow` regardless of whether Xcode's debugger attaches, so external tools like `/usr/bin/sample <pid>` can still profile a run launched here. Scoped to the `Kernova` app target only. `make build`/`make test` never launch the app, so neither scheme changes their behavior.

## Worktree LaunchServices cleanup

Every worktree build registers its app bundles with LaunchServices. When the worktree is removed those registrations become ghosts — stale entries that accumulate and have previously hijacked UTI and name resolution.

Debris of *removed* worktrees self-heals. The post-checkout hook runs `Tools/ghosts.sh --sweep` on every *initial* checkout (`git worktree add` passes the null ref as `$1`; a plain `git switch` never pays the multi-second `lsregister` dump). The sweep unregisters every registered Kernova path that no longer exists on disk — the current `app.kernova.*` identifiers and the legacy `com.kernova.app` one alike — and evicts DerivedData arenas orphaned by removed worktrees, skipping any arena a process is still running from.

**Live** stray copies still need the on-demand tools: `make ghosts` reports; `make clean-ghosts` also unregisters, prunes, and evicts. `make ghosts` inventories live `Kernova.app` copies under Trash and `~/Library/Developer/Xcode/DerivedData`, and flags any that outrank the installed `/Applications` copy in the LaunchServices `CFBundleVersion` election — Spotlight indexes neither location, so `mdfind` alone misses them.

`-kill` has been removed from current macOS's `lsregister` ("dangerous and no longer useful", per `lsregister -h`), and a plain `lsregister -u <path>` reliably unregisters an entry even once its path is gone (verified empirically 2026-07-08).
