# Kernova build & test invocations.
#
# These targets own the `xcodebuild` invocations — the flags are not the
# obvious ones, so never hand-write one. Inside Xcode, just use the IDE
# (CMD-B / CMD-U); this Makefile is for terminal, CI, and tooling use.
#
# CI mirrors the build/test invocation by hand in
# .github/workflows/xcodebuild-test.yml — keep changes to the shared
# xcodebuild flags in sync there.

PROJECT      := Kernova.xcodeproj
SCHEME       := Kernova
DESTINATION  := platform=macOS

# OMIT -derivedDataPath on a dev machine so a terminal build shares the Xcode
# GUI's arena; pass it under CI so artifacts land at a fixed path. Omitting the
# flag is load-bearing — docs/BUILD.md "Derived data and build arenas".
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
.PHONY: help build test test-suite test-package clean format lint install-hooks check-hooks doctor ghosts clean-ghosts

# Generated from the `## ` annotation on each target line below — annotate new
# targets there and this listing (and its ordering) follows automatically.
help:
	@printf 'Kernova build targets:\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-15s %s\n", $$1, $$2}'
	@printf '\n'
	@printf '  make test-suite requires SUITE=<Target/Suite>, e.g. SUITE=KernovaTests/VMConfigurationTests\n'
	@printf '  Append CONFIGURATION=Release to build/test in Release (default: Debug)\n'

# One-time per clone: point this repo's git at the checked-in hooks —
# `.githooks/pre-push` runs `make lint` before each push (bypass an
# individual push with `git push --no-verify`), and `.githooks/post-checkout`
# sets up fresh worktrees: it copies the gitignored files listed in
# .worktreeinclude from the main checkout. Per-repo config (no `--global`);
# core.hooksPath is shared by all worktrees of this repo.
install-hooks: ## Point git at .githooks/ (pre-push lint; post-checkout worktree setup)
	git config core.hooksPath .githooks
	@echo 'Hooks installed. Pre-push runs `make lint`; post-checkout sets up new worktrees (.worktreeinclude copies).'

# Silent when the hooks are wired up; otherwise a one-line nudge. Runs as a
# prerequisite of the build/test targets so contributors who skipped the
# install step see the reminder on their first build instead of only when
# CI fails on their PR. Detection delegates to Tools/hooks-installed.sh —
# shared with doctor.sh — which verifies the configured path actually
# contains the hooks rather than string-comparing against ".githooks" (an
# absolute path that resolves correctly also counts as installed).
check-hooks:
	@Tools/hooks-installed.sh >/dev/null || printf 'Note: git hooks are not installed. Run `make install-hooks` (one-time per clone) to lint before push and auto-set-up new worktrees.\n' >&2

build: check-hooks ## Build the app for macOS
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
# routine the post-checkout sweep and `clean-ghosts` use. A missing path is a
# no-op, so both candidates are passed unconditionally.
clean: ## Remove this checkout's build arenas (in-worktree DerivedData/ and the resolved Xcode arena)
	@Tools/ghosts.sh --evict '$(DERIVED_DATA_ROOT)'
	@arena=$$(Tools/derived-data-path.sh 2>/dev/null); \
	case "$$arena" in \
		''|'$(CURDIR)'/*) ;; \
		*) Tools/ghosts.sh --evict "$$arena" ;; \
	esac

test: check-hooks ## Run the full test suite (all three test targets via Kernova.xctestplan)
	xcodebuild $(XCODEBUILD_FLAGS) test

# `xcrun` so the toolchain matches the one selected via `xcode-select`
# (same rationale as the `xcrun swift-format` invocation above).
test-package: ## Run only the KernovaKit SwiftPM package tests
	xcrun swift test --package-path KernovaKit

test-suite: check-hooks ## Run a single test suite (SUITE=<Target/Suite>; see below)
	@if [ -z "$(SUITE)" ]; then \
		echo 'Usage: make test-suite SUITE=<Target/Suite>' >&2; \
		echo 'Example: make test-suite SUITE=KernovaTests/VMConfigurationTests' >&2; \
		exit 2; \
	fi
	xcodebuild $(XCODEBUILD_FLAGS) test -only-testing:$(SUITE)

format: ## Rewrite Swift sources in place via swift-format
	@test -n '$(strip $(SWIFT_SOURCE_DIRS))' || { echo 'No tracked Swift sources found — not a git checkout?' >&2; exit 1; }
	$(SWIFT_FORMAT) format --in-place --recursive $(SWIFT_SOURCE_DIRS)

# One lint target for the whole repo.
#
# Shell: `bash -n` always (ships with macOS, catches syntax errors); shellcheck
# for real static analysis when installed — optional locally (brew install
# shellcheck), REQUIRED on CI ($CI is set by GitHub Actions) so findings gate
# merges rather than silently skipping. Project-wide directives live in
# .shellcheckrc. Shell runs first: it is the faster half, so an obvious script
# error surfaces without waiting on swift-format.
lint: ## Lint Swift sources (swift-format --strict), shell scripts, and docs
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
	@bash Tools/check-docs.sh

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
# outrank the installed /Applications copy in the LaunchServices
# CFBundleVersion election (#454). `ghosts` only reports; `clean-ghosts` also
# unregisters/kills/prunes/evicts, prompting only for live competing copies.
ghosts: ## Report stale/competing Kernova Launch Services, process, and worktree registrations
	@Tools/ghosts.sh

clean-ghosts: ## Same as ghosts, but also unregisters/kills/prunes/evicts what it finds
	@Tools/ghosts.sh --fix
