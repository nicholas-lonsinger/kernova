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
# GUI's arena; pass it under CI so artifacts land at a fixed path. Omitting is
# load-bearing: the flag, even at the identical resolved path, records a
# different arena identity in the build description, and every CLI↔GUI switch
# then rebuilds the whole graph both ways (measured in Relative mode).
DERIVED_DATA_FLAG  := -derivedDataPath $(DERIVED_DATA)
# The index store serves an editor CI does not have. The compilation cache is on
# project-wide in Config/Base.xcconfig and repeated here because a package
# target never reads a project xcconfig. The limit is below any build's
# output, so every build rolls the store over into a fresh generation that
# holds exactly what that build produced or looked up — the workflow prunes
# the generation left behind and saves the rest.
CI_FLAGS           := COMPILER_INDEX_STORE_ENABLE=NO \
                      COMPILATION_CACHE_ENABLE_CACHING=YES \
                      COMPILATION_CACHE_LIMIT_SIZE=1M
RESULT_BUNDLE_FLAG := -resultBundlePath $(RESULT_BUNDLE)
endif

# Build configuration, passed explicitly rather than relying on the scheme's
# per-action default (Debug). Override on the command line to build/test in
# Release, e.g. `make build CONFIGURATION=Release`.
CONFIGURATION ?= Debug

# Plugin validation is an interactive trust prompt no terminal build can answer.
XCODEBUILD_FLAGS = -project $(PROJECT) \
                   -scheme $(SCHEME) \
                   -destination '$(DESTINATION)' \
                   $(DERIVED_DATA_FLAG) \
                   -configuration $(CONFIGURATION) \
                   -skipPackagePluginValidation \
                   $(CI_FLAGS)

# Every command that runs xcodebuild against this checkout — Periphery's
# included, which resolves packages into the checkout's shared files — runs
# under the checkout's build lock (Tools/checkout-lock.sh), so a second run
# waits for the first rather than sharing its build arena; a Tools script that
# runs xcodebuild takes the lock itself. `test-unhosted` runs without it:
# SwiftPM serializes runs on .build itself. A recipe with several such commands
# holds the lock across all of them by running its `locked-` twin under it, so
# no other run starts in between.
LOCKED       := Tools/checkout-lock.sh
LOCKED_TWIN   = +@$(LOCKED) $(MAKE) --no-print-directory locked-$@

# swift-format ships with the Xcode toolchain (Xcode 26+); use xcrun so the
# command resolves the same binary in CI and locally without a brew install.
SWIFT_FORMAT := xcrun swift-format

# The fixture suites for the skill scripts, Tools/lib, and the lint checks that
# have one. Each drives its code through every verdict against recorded
# fixtures — no Xcode, no network, seconds to run — which is what lets `lint`
# gate them, and the pre-push hook with it.
FIXTURE_TESTS := .agents/skills/after-merge/tests/run.sh \
                 .agents/skills/make-verdict/tests/run.sh \
                 Tools/tests/worktrees.sh \
                 Tools/tests/checkout-lock.sh \
                 Tools/tests/attest.sh \
                 Tools/tests/arena-label.sh \
                 Tools/tests/check-config-decoding.sh \
                 Tools/tests/check-test-waits.sh \
                 Tools/tests/check-exit-tests.sh \
                 Tools/tests/check-self-activation.sh

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
.PHONY: help build locked-build build-for-testing locked-build-for-testing test attest test-without-building test-suite test-unhosted test-unhosted-tsan swift-toolchain linux-build clean locked-clean format lint setup install-hooks check-hooks install-lsp dead-code doctor ghosts clean-ghosts

# Generated from the `## ` annotation on each target line below — annotate new
# targets there and this listing (and its ordering) follows automatically.
help:
	@printf 'Kernova build targets:\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-22s %s\n", $$1, $$2}'
	@printf '\n'
	@printf '  make test-suite requires SUITE=<Target/Suite>, e.g. SUITE=KernovaVirtualizationTests/ConfigurationBuilderTests or SUITE=KernovaCoreTests/VMConfigurationTests\n'
	@printf '  Append CONFIGURATION=Release to build/test in Release (default: Debug)\n'
	@printf '  Prefix CI=1 to build/test with the CI-only settings (fixed DerivedData path, no index store)\n'

# Everything a fresh clone needs beyond Xcode itself, composed from the
# targets below so each piece is also runnable on its own. Every step is
# idempotent, so rerun it whenever the environment drifts. It ends with
# `doctor`, which reports the state the run produced.
setup: install-hooks ## Set up a clone: hooks, Homebrew tools, LSP config, Periphery, then doctor
	@Tools/brew-install.sh shellcheck gh xcode-build-server
	@Tools/lsp-config.sh '$(PROJECT)' '$(SCHEME)'
	@Tools/install-periphery.sh >/dev/null
	@Tools/doctor.sh

# One-time per clone: point this repo's git at the checked-in hooks —
# `.githooks/pre-push` runs `make lint` before each push (bypass an
# individual push with `git push --no-verify`), `.githooks/commit-msg` checks
# that an agent's co-author trailer names the model and version, and
# `.githooks/post-checkout` sets up fresh worktrees: it copies the gitignored
# files listed in .worktreeinclude from the main checkout. Per-repo config
# (no `--global`); core.hooksPath is shared by all worktrees of this repo.
install-hooks: ## Point git at .githooks/ (pre-push lint; commit-msg model trailer; post-checkout worktree setup)
	git config core.hooksPath .githooks
	@echo 'Hooks installed. Pre-push runs `make lint`; commit-msg checks that the co-author trailer names the model and version; post-checkout sets up new worktrees (.worktreeinclude copies).'

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
	$(LOCKED_TWIN)

locked-build:
	xcodebuild $(XCODEBUILD_FLAGS) build
	$(PRINT_BUILD_BINARY)

build-for-testing: check-hooks ## Compile the app and test bundles without running them
	$(LOCKED_TWIN)

locked-build-for-testing:
	xcodebuild $(XCODEBUILD_FLAGS) build-for-testing
	$(PRINT_BUILD_BINARY)

# Query resolved settings after success: an up-to-date build need not log a
# link or signing command from which a product path could be recovered.
define PRINT_BUILD_BINARY
@settings=$$(xcodebuild $(XCODEBUILD_FLAGS) -showBuildSettings) && \
printf '%s\n' "$$settings" | awk '\
    /^Build settings for action / { app = ($$0 ~ / and target Kernova:$$/) } \
    app && /^ *TARGET_BUILD_DIR = / { sub(/^ *TARGET_BUILD_DIR = /, ""); dir = $$0 } \
    app && /^ *EXECUTABLE_PATH = / { sub(/^ *EXECUTABLE_PATH = /, ""); executable = $$0 } \
    END { \
        if (dir == "" || executable == "") { print "error: could not resolve Kernova executable path" > "/dev/stderr"; exit 1 } \
        print "binary=" dir "/" executable \
    }'
endef

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
	$(LOCKED_TWIN)

locked-clean:
	@Tools/ghosts.sh --evict '$(DERIVED_DATA_ROOT)'
	@arena=$$(Tools/derived-data-path.sh 2>/dev/null); \
	case "$$arena" in \
		''|'$(CURDIR)'/*) ;; \
		*) Tools/ghosts.sh --evict "$$arena" ;; \
	esac

test: check-hooks ## Run the full test suite (every test target in Kernova.xctestplan); a passing run is recorded for `make attest`
	$(LOCKED) Tools/attest.sh record -- xcodebuild $(XCODEBUILD_FLAGS) test

attest: check-hooks ## Post the `Test Attestation` status on the pushed HEAD, reusing a passing `make test` of the same content or running one
	@Tools/attest.sh

# The `rm -rf` fires only when RESULT_BUNDLE_FLAG is set (CI): xcodebuild
# refuses a -resultBundlePath that already exists, and outside CI this target
# passes no such flag and must not touch artifacts/.
test-without-building: check-hooks ## Run the test plan against an existing build-for-testing product
	@test -z '$(RESULT_BUNDLE_FLAG)' || rm -rf '$(RESULT_BUNDLE)'
	$(LOCKED) xcodebuild $(XCODEBUILD_FLAGS) $(RESULT_BUNDLE_FLAG) test-without-building

# The local packages' own test targets, which run with no app as their host:
# every top-level directory holding a Package.swift, derived like
# SWIFT_SOURCE_DIRS. `xcrun` so the toolchain matches the one selected via
# `xcode-select` (same rationale as the `xcrun swift-format` invocation above).
PACKAGE_DIRS := $(shell git ls-files '*/Package.swift' | awk -F/ 'NF == 2 { print $$1 }')

test-unhosted: ## Run only the unhosted lanes: each local package's tests under `swift test`
	@test -n '$(strip $(PACKAGE_DIRS))' || { echo 'No tracked Package.swift found — not a git checkout?' >&2; exit 1; }
	@failed=''; \
	for package in $(PACKAGE_DIRS); do \
		xcrun swift test $(SWIFT_TEST_FLAGS) --package-path "$$package" || failed="$$failed $$package"; \
	done; \
	if [ -n "$$failed" ]; then echo "test-unhosted: tests failed in:$$failed" >&2; exit 1; fi

# TSan drops itself from DYLD_INSERT_LIBRARIES once loaded (its `strip_env`
# flag, on by default), so an exit test's child — the test host relaunched —
# loads the instrumented test bundle without the runtime and aborts in
# `VerifyInterceptorsWorking` before the body runs. strip_env=0 keeps the
# runtime in that child.
test-unhosted-tsan: ## Run the unhosted lanes under Thread Sanitizer
	@TSAN_OPTIONS='strip_env=0 $(TSAN_OPTIONS)' $(MAKE) --no-print-directory test-unhosted SWIFT_TEST_FLAGS=--sanitize=thread

swift-toolchain: ## Install swiftly, the swift.org toolchain .swift-version pins, and its Static Linux SDK
	@Tools/install-swift-toolchain.sh >/dev/null

# The targets KernovaKit/Package.swift declares off macOS. A cross build
# evaluates the manifest on this Mac, where every target is declared, so it
# names them; the Linux and Windows CI jobs build the manifest's own set. Its
# own scratch path keeps the swift.org toolchain's build state apart from the
# Xcode toolchain's, which `test-unhosted` uses.
PORTABLE_TARGETS := KernovaSynchronization KernovaLogging

linux-build: ## Cross-build the portable KernovaKit targets for aarch64 Linux (static musl) with the pinned swift.org toolchain
	@swiftly=$$(Tools/install-swift-toolchain.sh) || exit 1; \
	"$$swiftly" run swift build "+$$(cat .swift-version)" --package-path KernovaKit \
		--scratch-path KernovaKit/.build/swiftly --swift-sdk aarch64-swift-linux-musl \
		$(addprefix --target ,$(PORTABLE_TARGETS))

test-suite: check-hooks ## Run a single test suite (SUITE=<Target/Suite>; see below)
	@if [ -z "$(SUITE)" ]; then \
		echo 'Usage: make test-suite SUITE=<Target/Suite>' >&2; \
		echo 'Example: make test-suite SUITE=KernovaCoreTests/VMConfigurationTests' >&2; \
		exit 2; \
	fi
	$(LOCKED) xcodebuild $(XCODEBUILD_FLAGS) test -only-testing:$(SUITE)

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
lint: ## Lint Swift sources (swift-format --strict), shell scripts, the fixture suites, docs, entitlements, the scripting definition and exported types the app and test host both declare, build-setting layering, build phases, the test plan's wait allowance, test-only seam gating, real-clock sleeps and numeric wait deadlines in tests, exit tests in a target of their own, config-field decoding, the app's Launch Services self-activation and AppPresence routing, the local package references, and KernovaCore's import allowlist
	@for f in $(SHELL_SOURCES); do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SHELL_SOURCES); \
	elif [ -n "$${CI:-}" ]; then \
		echo 'lint: shellcheck is required on CI but not installed' >&2; \
		exit 1; \
	else \
		echo 'lint: shellcheck not installed — skipping shell static analysis (brew install shellcheck)'; \
	fi
	@bash Tools/tests/git-isolation.sh $(FIXTURE_TESTS)
	@test -n '$(strip $(SWIFT_SOURCE_DIRS))' || { echo 'No tracked Swift sources found — not a git checkout?' >&2; exit 1; }
	$(SWIFT_FORMAT) lint --strict --recursive $(SWIFT_SOURCE_DIRS)
	@bash Tools/check-docs.sh
	@bash Tools/check-entitlements.sh
	@bash Tools/check-test-host-declarations.sh
	@bash Tools/check-agent-deployment-floor.sh
	@bash Tools/check-test-plan-allowance.sh
	@bash Tools/check-test-seams.sh
	@bash Tools/check-test-waits.sh
	@bash Tools/check-exit-tests.sh
	@bash Tools/check-config-decoding.sh
	@bash Tools/check-self-activation.sh
	@bash Tools/check-build-settings-layering.sh
	@bash Tools/check-build-phases.sh
	@bash Tools/check-package-reference.sh
	@bash Tools/check-core-imports.sh

# Unused-code scan, reading .periphery.yml, over one fixed arena per checkout.
# Periphery's own build would go to ~/Library/Caches/com.github.peripheryapp
# under a name hashed from its schemes in a Swift `Set`'s per-process order, a
# new multi-gigabyte arena most runs; the GUI's arena, indexed while editing,
# is no single build's index. The flags are Periphery 3.x's own plus
# `-skipPackagePluginValidation` and the compilation cache off: a compile the
# cache serves writes no index unit, leaving the unit an earlier compile wrote
# — after a revert, a cached scan reported 27 findings in code that no longer
# existed (Xcode 27.1). Stdout carries Periphery's report alone —
# .github/workflows/dead-code.yml greps it — so the builds write to stderr. The
# built apps are unregistered from Launch Services on the way out, whatever
# the outcome, so a scan's build never wins the version election.
PERIPHERY_DERIVED_DATA := $(DERIVED_DATA_ROOT)/Periphery
PERIPHERY_SCHEMES       = $(shell awk '/^schemes:/ { on = 1; next } on && /^  - / { print $$2; next } on && !/^ *(\#|$$)/ { on = 0 }' .periphery.yml)

dead-code: ## Scan for unused code with Periphery (builds every scheme first; minutes)
	$(LOCKED_TWIN)

locked-dead-code:
	@trap "Tools/ghosts.sh --unregister '$(PERIPHERY_DERIVED_DATA)/Build/Products' >&2" EXIT; \
	periphery=$$(Tools/install-periphery.sh) || exit 1; \
	schemes='$(PERIPHERY_SCHEMES)'; \
	[ -n "$$schemes" ] || { echo 'dead-code: no schemes listed in .periphery.yml' >&2; exit 1; }; \
	for scheme in $$schemes; do \
		xcodebuild -project $(PROJECT) -scheme "$$scheme" -destination '$(DESTINATION)' \
			-derivedDataPath $(PERIPHERY_DERIVED_DATA) -parallelizeTargets -quiet \
			-skipPackagePluginValidation build-for-testing \
			CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT=dwarf \
			COMPILER_INDEX_STORE_ENABLE=YES INDEX_ENABLE_DATA_STORE=YES \
			COMPILATION_CACHE_ENABLE_CACHING=NO >&2 || exit 1; \
	done; \
	"$$periphery" scan --disable-update-check \
		--index-store-path $(PERIPHERY_DERIVED_DATA)/Index.noindex/DataStore

# Environment sanity check: verifies the local toolchain (macOS, Xcode, Swift,
# swift-format), signing, optional tooling, and repo setup (git hooks,
# .worktreeinclude) match what Kernova needs to build, lint, and push. A
# starting point — extend Tools/doctor.sh with more checks over time. Exits
# non-zero if any required check fails, so it's CI-usable too.
doctor: ## Check the local toolchain, signing, optional tooling, and repo setup
	@Tools/doctor.sh

ghosts: ## Report stale/competing Kernova Launch Services registrations, processes, worktrees, and build arenas
	@Tools/ghosts.sh

clean-ghosts: ## Same as ghosts, but also unregisters/kills/prunes/trashes/removes/evicts what it finds
	@Tools/ghosts.sh --fix
