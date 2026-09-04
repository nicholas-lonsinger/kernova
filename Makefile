# Kernova build & test invocations.
#
# These targets own the `xcodebuild` invocations — the flags are not the
# obvious ones, so never hand-write one. Inside Xcode, just use the IDE
# (CMD-B / CMD-U); this Makefile is for terminal, CI, and tooling use.

PROJECT      := Kernova.xcodeproj
SCHEME       := Kernova
DESTINATION  := platform=macOS

DERIVED_DATA_ROOT := DerivedData
DERIVED_DATA      := $(DERIVED_DATA_ROOT)/$(basename $(PROJECT))
RESULT_BUNDLE     := artifacts/TestResults.xcresult

# CI-only settings. `CI=1 make test` reproduces a CI build locally.
ifneq ($(strip $(CI)),)
# OMIT -derivedDataPath on a dev machine so a terminal build shares the Xcode
# GUI's arena; pass it under CI so artifacts land at a fixed path. Omitting the
# flag is load-bearing — docs/BUILD.md "Derived data and build arenas".
DERIVED_DATA_FLAG  := -derivedDataPath $(DERIVED_DATA)
# Plugin validation is an interactive trust prompt no runner can answer; the
# index store serves an editor CI does not have. The compilation cache is on
# project-wide in Config/Base.xcconfig; it is repeated here because a package
# target never reads a project xcconfig, and a command-line setting is the one
# form that reaches KernovaKit and SwiftProtobuf — the workflow's cache steps
# save and restore the store all of them fill.
CI_FLAGS           := -skipPackagePluginValidation \
                      COMPILER_INDEX_STORE_ENABLE=NO \
                      COMPILATION_CACHE_ENABLE_CACHING=YES
RESULT_BUNDLE_FLAG := -resultBundlePath $(RESULT_BUNDLE)
endif

# Build configuration, passed explicitly rather than relying on the scheme's
# per-action default (Debug). Override on the command line to build/test in
# Release, e.g. `make build CONFIGURATION=Release`.
CONFIGURATION ?= Debug

XCODEBUILD_FLAGS = -project $(PROJECT) \
                   -scheme $(SCHEME) \
                   -destination '$(DESTINATION)' \
                   $(DERIVED_DATA_FLAG) \
                   -configuration $(CONFIGURATION) \
                   $(CI_FLAGS)

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
.PHONY: help build build-for-testing test test-without-building test-suite test-package clean format lint setup install-hooks check-hooks install-lsp dead-code doctor ghosts clean-ghosts

# Generated from the `## ` annotation on each target line below — annotate new
# targets there and this listing (and its ordering) follows automatically.
help:
	@printf 'Kernova build targets:\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-22s %s\n", $$1, $$2}'
	@printf '\n'
	@printf '  make test-suite requires SUITE=<Target/Suite>, e.g. SUITE=KernovaTests/VMConfigurationTests\n'
	@printf '  Append CONFIGURATION=Release to build/test in Release (default: Debug)\n'
	@printf '  Prefix CI=1 to build/test with the CI-only settings (fixed DerivedData path, no index store)\n'

# Everything a fresh clone needs beyond Xcode itself, composed from the
# targets below so each piece is also runnable on its own. Every step is
# idempotent, so rerun it whenever the environment drifts. It ends with
# `doctor`, which reports the state the run produced.
setup: install-hooks ## Set up a clone: hooks, Homebrew tools, LSP config, Periphery, then doctor
	@Tools/brew-install.sh shellcheck gh protoc:protobuf xcode-build-server
	@Tools/lsp-config.sh '$(PROJECT)' '$(SCHEME)'
	@Tools/install-periphery.sh >/dev/null
	@Tools/doctor.sh

# One-time per clone: point this repo's git at the checked-in hooks —
# `.githooks/pre-push` runs `make lint` before each push (bypass an
# individual push with `git push --no-verify`), and `.githooks/post-checkout`
# sets up fresh worktrees: it copies the gitignored files listed in
# .worktreeinclude from the main checkout. Per-repo config (no `--global`);
# core.hooksPath is shared by all worktrees of this repo.
install-hooks: ## Point git at .githooks/ (pre-push lint; post-checkout worktree setup)
	git config core.hooksPath .githooks
	@echo 'Hooks installed. Pre-push runs `make lint`; post-checkout sets up new worktrees (.worktreeinclude copies).'

# Silent when the hooks are wired up, or under CI (which has no hooks to
# install); otherwise a one-line nudge. Runs as a prerequisite of the
# build/test targets so contributors who skipped the install step see the
# reminder on their first build instead of only when CI fails on their PR.
# Detection delegates to Tools/hooks-installed.sh — shared with doctor.sh —
# which verifies the configured path actually contains the hooks rather than
# string-comparing against ".githooks" (an absolute path that resolves
# correctly also counts as installed).
check-hooks:
	@if [ -z "$${CI:-}" ] && ! Tools/hooks-installed.sh >/dev/null; then \
		printf 'Note: git hooks are not installed. Run `make install-hooks` (one-time per clone) to lint before push and auto-set-up new worktrees.\n' >&2; \
	fi

# One-time per checkout: sourcekit-lsp reads compiler flags from a
# buildServer.json that xcode-build-server writes from Xcode's build log, so
# editors and Claude Code's Swift language server resolve imports and symbols
# across the project. The config names an absolute build root — every checkout
# writes its own, and .githooks/post-checkout writes a new worktree's when the
# tool is already installed.
install-lsp: ## Install xcode-build-server and write this checkout's buildServer.json
	@Tools/brew-install.sh xcode-build-server
	@Tools/lsp-config.sh '$(PROJECT)' '$(SCHEME)'

build: check-hooks ## Build the app for macOS
	xcodebuild $(XCODEBUILD_FLAGS) build

build-for-testing: check-hooks ## Compile the app and test bundles without running them
	xcodebuild $(XCODEBUILD_FLAGS) build-for-testing

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

# The `rm -rf` fires only when RESULT_BUNDLE_FLAG is set (CI): xcodebuild
# refuses a -resultBundlePath that already exists, and outside CI this target
# passes no such flag and must not touch artifacts/.
test-without-building: check-hooks ## Run the test plan against an existing build-for-testing product
	@test -z '$(RESULT_BUNDLE_FLAG)' || rm -rf '$(RESULT_BUNDLE)'
	xcodebuild $(XCODEBUILD_FLAGS) $(RESULT_BUNDLE_FLAG) test-without-building

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
lint: ## Lint Swift sources (swift-format --strict), shell scripts, docs, entitlements, and build-setting layering
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
	@bash Tools/check-entitlements.sh
	@bash Tools/check-headless-core.sh
	@bash Tools/check-agent-deployment-floor.sh
	@bash Tools/check-build-settings-layering.sh

# Unused-code scan, reading .periphery.yml. Periphery 3.x passes its own
# `-derivedDataPath`, `-quiet`, `build-for-testing`, `CODE_SIGNING_ALLOWED=NO`,
# and `COMPILER_INDEX_STORE_ENABLE=YES` to xcodebuild; only
# `-skipPackagePluginValidation` has to be appended, because the project
# consumes SwiftPM packages. That build is Periphery's own, into its own arena,
# so a scan takes minutes. Stdout carries Periphery's report and nothing else —
# .github/workflows/dead-code.yml redirects it to a file and greps it.
dead-code: ## Scan for unused code with Periphery (drives its own build; minutes)
	@periphery=$$(Tools/install-periphery.sh) && "$$periphery" scan --disable-update-check -- -skipPackagePluginValidation

# Environment sanity check: verifies the local toolchain (macOS, Xcode, Swift,
# swift-format), signing, optional tooling, and repo setup (git hooks,
# .worktreeinclude) match what Kernova needs to build, lint, and push. A
# starting point — extend Tools/doctor.sh with more checks over time. Exits
# non-zero if any required check fails, so it's CI-usable too.
doctor: ## Check the local toolchain, signing, optional tooling, and repo setup
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
