# Kernova build & test invocations.
#
# These targets own the `xcodebuild` invocations — the flags are not the
# obvious ones, so never hand-write one. Inside Xcode, just use the IDE
# (CMD-B / CMD-U); this Makefile is for terminal, CI, and tooling use.
#
# CI mirrors the build/test invocation by hand in
# .github/workflows/xcodebuild-test.yml — it can't run `make test` because
# the bootstrap prerequisite needs a signing identity the runner doesn't
# have — so keep changes to the shared xcodebuild flags in sync there.

PROJECT      := Kernova.xcodeproj
SCHEME       := Kernova
DESTINATION  := platform=macOS

# On a dev machine, OMIT -derivedDataPath so a terminal build follows the
# machine's Xcode derived-data preference — default per-path-hashed ~/Library
# location, Relative, or a per-user workspace override alike. A flag-less
# xcodebuild reads the same IDE setting and computes the identical build arena
# as the GUI — same location AND same arena identity — so terminal and Xcode
# builds share incremental state (switching is a null build). Passing
# -derivedDataPath, even with the identical resolved path, records a different
# arena identity in the build description, and every CLI<->GUI switch then
# re-runs the whole compile graph. Kernova adapts to the preference rather
# than prescribing one; tooling that needs the concrete arena path
# (`make clean`, Tools/ghosts.sh, Tools/doctor.sh) resolves it with
# Tools/derived-data-path.sh. See docs/BUILD.md "Derived data and build arenas".
#
# Only under CI does the explicit in-worktree flag remain: there is no GUI to
# share with, and a deterministic DerivedData/Kernova path keeps artifact
# handling simple (.github/workflows mirrors the same flag by hand).
#
# Evaluated lazily (recursive `=`, expanded via $(XCODEBUILD_FLAGS) inside the
# build/test recipes) so targets that never build — help, lint, format, clean —
# don't pay for the probe on every invocation.
DERIVED_DATA_ROOT := DerivedData
DERIVED_DATA      := $(DERIVED_DATA_ROOT)/$(basename $(PROJECT))
DERIVED_DATA_FLAG = $(shell \
	if [ -n "$${CI:-}" ]; then \
		printf -- '-derivedDataPath %s' '$(DERIVED_DATA)'; \
	fi)

# Build configuration, passed explicitly rather than relying on the scheme's
# per-action default (Debug). Override on the command line to build/test in
# Release, e.g. `make build CONFIGURATION=Release`.
CONFIGURATION ?= Debug

# Recursive (`=`) so DERIVED_DATA_FLAG above is resolved per-recipe, not at
# parse time.
XCODEBUILD_FLAGS = -project $(PROJECT) \
                   -scheme $(SCHEME) \
                   -destination '$(DESTINATION)' \
                   $(DERIVED_DATA_FLAG) \
                   -configuration $(CONFIGURATION)

# swift-format ships with the Xcode toolchain (Xcode 26+); use xcrun so the
# command resolves the same binary in CI and locally without a brew install.
SWIFT_FORMAT := xcrun swift-format

# Source roots for format/lint, derived from git rather than hand-maintained
# so a new target directory can't silently escape linting (locally and in CI,
# which runs `make lint`). Tracked files define the roots: an untracked .swift
# file inside an existing root is still covered (swift-format recurses), and a
# top-level .swift file would appear as its own entry, which swift-format
# accepts as a path argument. Shell sources are the tracked scripts (including
# the guest agent's double-clickable .command installers) plus the git hooks
# (shebang'd but extensionless).
SWIFT_SOURCE_DIRS := $(shell git ls-files '*.swift' | cut -d/ -f1 | sort -u)
SHELL_SOURCES     := $(shell git ls-files '*.sh' '*.command' .githooks)

.DEFAULT_GOAL := help
.PHONY: help build test test-suite test-package clean format lint install-hooks check-hooks bootstrap doctor ghosts clean-ghosts fp-reset

# Generated from the `## ` annotation on each target line below — annotate new
# targets there and this listing (and its ordering) follows automatically.
help:
	@printf 'Kernova build targets:\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-15s %s\n", $$1, $$2}'
	@printf '\n'
	@printf '  make test-suite requires SUITE=<Target/Suite>, e.g. SUITE=KernovaTests/VMConfigurationTests\n'
	@printf '  Append CONFIGURATION=Release to build/test in Release (default: Debug)\n'

# Derives this developer's signing team from their own certificate into the
# gitignored Config/Local.xcconfig (see Config/Base.xcconfig) — what makes a
# fresh clone build and sign with *your* team rather than a hardcoded one
# (#476). A prerequisite of build/test rather than a separate manual step, so
# a fresh clone's first `make build` just works; Tools/bootstrap-team.sh is
# idempotent (no-ops once Config/Local.xcconfig has a value), so this is cheap
# on every subsequent build. Re-derive with `Tools/bootstrap-team.sh --force`.
bootstrap: ## Derive your signing team into Config/Local.xcconfig (auto-run by build/test)
	@Tools/bootstrap-team.sh

# One-time per clone: point this repo's git at the checked-in hooks —
# `.githooks/pre-push` runs `make lint` before each push (bypass an
# individual push with `git push --no-verify`), and `.githooks/post-checkout`
# sets up fresh worktrees: it copies the gitignored files listed in
# .worktreeinclude from the main checkout, then bootstraps DEVELOPMENT_TEAM
# if still missing. Per-repo config (no `--global`); core.hooksPath is
# shared by all worktrees of this repo.
install-hooks: ## Point git at .githooks/ (pre-push lint; post-checkout worktree setup)
	git config core.hooksPath .githooks
	@echo 'Hooks installed. Pre-push runs `make lint`; post-checkout sets up new worktrees (.worktreeinclude copies + DEVELOPMENT_TEAM bootstrap).'

# Silent when the hooks are wired up; otherwise a one-line nudge. Runs as a
# prerequisite of the build/test targets so contributors who skipped the
# install step see the reminder on their first build instead of only when
# CI fails on their PR. Detection delegates to Tools/hooks-installed.sh —
# shared with doctor.sh — which verifies the configured path actually
# contains the hooks rather than string-comparing against ".githooks" (an
# absolute path that resolves correctly also counts as installed).
check-hooks:
	@Tools/hooks-installed.sh >/dev/null || printf 'Note: git hooks are not installed. Run `make install-hooks` (one-time per clone) to lint before push and auto-set-up new worktrees.\n' >&2

build: check-hooks bootstrap ## Build the app for macOS
	xcodebuild $(XCODEBUILD_FLAGS) build

# Removes both build arenas this checkout can have: the in-worktree
# DerivedData/ (CI-style explicit-flag builds, and Relative-mode machines) and
# the arena the machine's Xcode preference resolves to (the hashed ~/Library
# folder on default-location machines — where flag-less `make build` and GUI
# builds land). The resolver is authoritative for "where would a build go",
# so this cannot delete another project's folder; the $(CURDIR) guard just
# avoids a redundant second eviction when the arena is already inside the
# worktree.
#
# Both go through `Tools/ghosts.sh --evict`, the same unregister-then-delete
# routine the post-checkout sweep and `clean-ghosts` use. A bare `rm -rf`, what
# this target used to do, leaves Launch Services registrations pointing into the
# deleted arena, so `make clean` manufactured exactly the ghosts
# `make clean-ghosts` exists to remove — the two targets stepped on each other.
# --evict also refuses to delete an arena a running app is executing from, and
# prints each arena's size before removing it, since on a default-location
# machine this is the arena the Xcode GUI shares and discarding it costs a full
# rebuild. A missing path is a no-op, so both candidates are passed
# unconditionally.
clean: ## Remove this checkout's build arenas (in-worktree DerivedData/ and the resolved Xcode arena)
	@Tools/ghosts.sh --evict '$(DERIVED_DATA_ROOT)'
	@arena=$$(Tools/derived-data-path.sh 2>/dev/null); \
	case "$$arena" in \
		''|'$(CURDIR)'/*) ;; \
		*) Tools/ghosts.sh --evict "$$arena" ;; \
	esac

test: check-hooks bootstrap ## Run the full test suite (all three test targets via Kernova.xctestplan)
	xcodebuild $(XCODEBUILD_FLAGS) test

# `xcrun` so the toolchain matches the one selected via `xcode-select`
# (same rationale as the `xcrun swift-format` invocation above).
test-package: ## Run only the KernovaKit SwiftPM package tests
	xcrun swift test --package-path KernovaKit

test-suite: check-hooks bootstrap ## Run a single test suite (SUITE=<Target/Suite>; see below)
	@if [ -z "$(SUITE)" ]; then \
		echo 'Usage: make test-suite SUITE=<Target/Suite>' >&2; \
		echo 'Example: make test-suite SUITE=KernovaTests/VMConfigurationTests' >&2; \
		exit 2; \
	fi
	xcodebuild $(XCODEBUILD_FLAGS) test -only-testing:$(SUITE)

format: ## Rewrite Swift sources in place via swift-format
	@test -n '$(strip $(SWIFT_SOURCE_DIRS))' || { echo 'No tracked Swift sources found — not a git checkout?' >&2; exit 1; }
	$(SWIFT_FORMAT) format --in-place --recursive $(SWIFT_SOURCE_DIRS)

# One lint target, covering both languages. The shell half was `make lint-shell`
# until nothing was found to invoke it: CI and .githooks/pre-push both run
# `make lint`, every other mention was prose, and the whole Swift pass costs 4
# seconds more than the shell pass alone — too little to justify a second
# command in `make help`.
#
# Shell: `bash -n` always (ships with macOS, catches syntax errors); shellcheck
# for real static analysis when installed — optional locally (brew install
# shellcheck), REQUIRED on CI ($CI is set by GitHub Actions) so findings gate
# merges rather than silently skipping. Project-wide directives live in
# .shellcheckrc. Shell runs first: it is the faster half, so an obvious script
# error surfaces without waiting on swift-format.
lint: ## Lint Swift sources (swift-format --strict) and shell scripts
	@for f in $(SHELL_SOURCES); do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SHELL_SOURCES); \
	elif [ -n "$${CI:-}" ]; then \
		echo 'lint: shellcheck is required on CI but not installed' >&2; \
		exit 1; \
	else \
		echo 'lint: shellcheck not installed — skipping shell static analysis (brew install shellcheck)'; \
	fi
	@test -n '$(strip $(SWIFT_SOURCE_DIRS))' || { echo 'No tracked Swift sources found — not a git checkout?' >&2; exit 1; }
	$(SWIFT_FORMAT) lint --strict --recursive $(SWIFT_SOURCE_DIRS)

# Environment sanity check: verifies the local toolchain (macOS, Xcode, Swift,
# swift-format) and repo setup (git hooks, .worktreeinclude) match what Kernova
# needs to build, lint, and push. A starting point — extend Tools/doctor.sh
# with more checks over time. Exits non-zero if any required check fails, so
# it's CI-usable too.
doctor: ## Check the local toolchain (macOS, Xcode, Swift, swift-format) and repo setup
	@Tools/doctor.sh

# Diagnoses ghost Launch Services registrations, orphaned DerivedData build
# arenas in the global ~/Library location, orphaned processes, and prunable
# git worktrees left behind by torn-down worktrees (the post-checkout hook
# sweeps registrations and arenas on new checkouts; this reports whatever
# remains) — plus LIVE on-disk Kernova.app copies (Trash, DerivedData) that
# outrank the installed /Applications copy in the LaunchServices/PluginKit
# CFBundleVersion election (#454). `ghosts` only reports; `clean-ghosts` also
# unregisters/kills/prunes/evicts, prompting only for live competing copies.
ghosts: ## Report stale/competing Kernova Launch Services, process, and worktree registrations
	@Tools/ghosts.sh

clean-ghosts: ## Same as ghosts, but also unregisters/kills/prunes/evicts what it finds
	@Tools/ghosts.sh --fix

# Restarts the File Provider daemon to clear stale Kernova domain/extension
# bindings — e.g. after a rebuild leaves fileproviderd pointing at a deleted or
# moved extension binary (Copy to Mac then beeps because the extension can't
# launch), or a domain wedged in a dead-end state. Kept separate from
# clean-ghosts and opt-in because it briefly interrupts ALL File Providers
# (iCloud Drive reconnects within seconds). macOS 26's fileproviderctl has no
# domain-remove command; the app self-heals a dead domain on next launch.
fp-reset: ## Restart fileproviderd to clear stale Kernova File Provider bindings
	@printf 'Restarting fileproviderd to clear stale Kernova File Provider bindings...\n'
	@printf '(briefly interrupts all File Providers; iCloud Drive reconnects in a few seconds)\n'
	@killall fileproviderd 2>/dev/null && printf 'fileproviderd restarted.\n' || printf 'fileproviderd was not running; it will start on demand.\n'
