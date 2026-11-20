# Kernova build & test invocations.
#
# These targets own the `xcodebuild` invocations, with the flags
# Tools/lib/xcodebuild-flags.sh gives them — they are not the obvious ones, so
# never hand-write one. Inside Xcode, just use the IDE
# (CMD-B / CMD-U); this Makefile is for terminal, CI, and tooling use.

XCODEBUILD_LIB := . Tools/lib/xcodebuild-flags.sh
PROJECT        := $(shell bash -c '$(XCODEBUILD_LIB) && echo "$$kernova_project"')
SCHEME         := $(shell bash -c '$(XCODEBUILD_LIB) && echo "$$kernova_scheme"')
DESTINATION    := $(shell bash -c '$(XCODEBUILD_LIB) && echo "$$kernova_destination"')

DERIVED_DATA_ROOT := DerivedData
RESULT_BUNDLE     := artifacts/TestResults.xcresult

ifneq ($(strip $(CI)),)
RESULT_BUNDLE_FLAG := -resultBundlePath $(RESULT_BUNDLE)
endif

# Override on the command line to build in Release, e.g.
# `make build CONFIGURATION=Release`. `make test` tests Debug only.
CONFIGURATION ?= Debug

# Tools/lib/xcodebuild-flags.sh owns the flags; CI is passed in so a
# command-line `CI=1` reaches it as an environment one does.
XCODEBUILD_PROJECT_FLAGS := $(shell bash -c '$(XCODEBUILD_LIB) && xcodebuild_project_flags')
XCODEBUILD_FLAGS = $(shell CI='$(CI)' bash -c '$(XCODEBUILD_LIB) && xcodebuild_flags "$$1"' _ '$(CONFIGURATION)')

# Every command that runs xcodebuild against this checkout — Periphery's
# included, which resolves packages into the checkout's shared files — runs
# under the checkout's build lock (Tools/checkout-lock.sh), so a second run
# waits for the first rather than sharing its build arena; a Tools script that
# runs xcodebuild takes the lock itself. `test-unhosted` runs no xcodebuild,
# so it runs without it. A recipe with several such commands
# holds the lock across all of them by running its `locked-` twin under it, so
# no other run starts in between.
LOCKED       := Tools/checkout-lock.sh
LOCKED_TWIN   = +@$(LOCKED) $(MAKE) --no-print-directory locked-$@

# swift-format ships with the Xcode toolchain (Xcode 26+); use xcrun so the
# command resolves the same binary in CI and locally without a brew install.
SWIFT_FORMAT := xcrun swift-format

SWIFT_SOURCE_DIRS := $(shell bash -c '. Tools/lib/swift-roots.sh && swift_roots')

.DEFAULT_GOAL := help
.PHONY: help build locked-build build-for-testing locked-build-for-testing test attest test-without-building test-suite test-unhosted test-unhosted-tsan swift-toolchain ubuntu-sdk linux-build clean locked-clean format lint setup install-hooks check-hooks install-lsp dead-code locked-dead-code dead-code-targets doctor ghosts clean-ghosts

# Generated from the `## ` annotation on each target line below — annotate new
# targets there and this listing (and its ordering) follows automatically.
help:
	@printf 'Kernova build targets:\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-22s %s\n", $$1, $$2}'
	@printf '\n'
	@printf '  make test-suite requires SUITE=<Target/Suite>, e.g. SUITE=KernovaVirtualizationTests/ConfigurationBuilderTests or SUITE=KernovaCoreTests/VMConfigurationTests\n'
	@printf '  Append CONFIGURATION=Release to build or test-without-building in Release (default: Debug); make test runs Debug only\n'
	@printf '  Prefix CI=1 to build/test with the CI-only settings (fixed DerivedData path, no index store)\n'

# Everything a fresh clone needs beyond Xcode itself, composed from the
# targets below so each piece is also runnable on its own. Every step is
# idempotent, so rerun it whenever the environment drifts. It ends with
# `doctor`, which reports the state the run produced.
setup: install-hooks ## Set up a clone: hooks, Homebrew tools, the swift.org toolchain, the Ubuntu SDK, LSP config, Periphery, then doctor
	@Tools/brew-install.sh shellcheck gh xcode-build-server
	@Tools/install-swift-toolchain.sh >/dev/null
	@Tools/install-ubuntu-sdk.sh >/dev/null
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
	@Tools/built-app.sh $(XCODEBUILD_FLAGS)

build-for-testing: check-hooks ## Compile the app and test bundles without running them, then check the built app's weak links
	$(LOCKED_TWIN)

locked-build-for-testing:
	xcodebuild $(XCODEBUILD_FLAGS) build-for-testing
	@Tools/built-app.sh --check-weak-links $(XCODEBUILD_FLAGS)

clean: ## Remove this checkout's build arenas (in-worktree DerivedData/ and its arenas in Xcode's DerivedData folder)
	$(LOCKED_TWIN)

locked-clean:
	@Tools/build-arenas.sh clean

test: check-hooks ## Run the full test suite (every test target in Kernova.xctestplan) in Debug, then check the built app's weak links; a passing run is recorded for `make attest`
	@test '$(CONFIGURATION)' = Debug || { echo 'make test runs Debug only, the build its record covers; build-for-testing and test-without-building take CONFIGURATION=$(CONFIGURATION)' >&2; exit 2; }
	Tools/attest.sh record test

attest: check-hooks ## Post the `Commit Attestation` status on the pushed HEAD, reusing a passing `make lint` and `make test` of the same content or running them
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
		bash -c '. Tools/lib/package-pins.sh && with_package_pins "$$1" xcrun swift test -- "$${@:2}"' _ "$$package" $(SWIFT_TEST_FLAGS) || failed="$$failed $$package"; \
	done; \
	if [ -n "$$failed" ]; then echo "test-unhosted: tests failed in:$$failed" >&2; exit 1; fi

# TSan drops itself from DYLD_INSERT_LIBRARIES once loaded (its `strip_env`
# flag, on by default), so an exit test's child — the test host relaunched —
# loads the instrumented test bundle without the runtime and aborts in
# `VerifyInterceptorsWorking` before the body runs. strip_env=0 keeps the
# runtime in that child.
test-unhosted-tsan: ## Run the unhosted lanes under Thread Sanitizer
	@TSAN_OPTIONS='strip_env=0 $(TSAN_OPTIONS)' $(MAKE) --no-print-directory test-unhosted SWIFT_TEST_FLAGS=--sanitize=thread

# Every other target builds only the tracked pins and fails once a manifest's
# requirement no longer admits them; this rewrites the tracked pin files — the
# Xcode workspace's, which every top-level package takes, and Tools/DeadCode's.
.PHONY: resolve-packages
resolve-packages: ## Re-resolve the tracked Package.resolved files after a package requirement changes
	$(LOCKED) xcodebuild -project $(PROJECT) -resolvePackageDependencies
	xcrun swift package resolve --disable-experimental-prebuilts --package-path Tools/DeadCode

swift-toolchain: ## Install swiftly, the swift.org toolchain .swift-version pins, and its Static Linux SDK
	@Tools/install-swift-toolchain.sh >/dev/null

ubuntu-sdk: ## Generate and install the Ubuntu SDK the Linux half of `make dead-code` cross-builds with (once; minutes)
	@Tools/install-ubuntu-sdk.sh >/dev/null

# Its own scratch path keeps the swift.org toolchain's build state apart from
# the Xcode toolchain's, which `test-unhosted` uses.
linux-build: ## Cross-build the portable KernovaKit targets for aarch64 Linux (static musl) with the pinned swift.org toolchain
	@Tools/install-swift-toolchain.sh >/dev/null && \
	bash -c '. Tools/lib/linux-swift.sh && linux_swift build --scratch-path KernovaKit/.build/swiftly --swift-sdk "$$(static_sdk_id "$$(pinned_swift_version)")" --triple aarch64-swift-linux-musl'

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

lint: ## Run Tools/lint.sh: shell analysis, the Tools/check-*.sh checks, swift-format --strict and the fixture suites; a passing run is recorded for `make attest`
	@Tools/attest.sh record lint

# The macOS half of the dead-code scan, reading .periphery.yml, over one fixed
# arena per checkout. Periphery's own build would go to
# ~/Library/Caches/com.github.peripheryapp under a name hashed from its schemes
# in a Swift `Set`'s per-process order, a new multi-gigabyte arena most runs;
# the GUI's arena, indexed while editing, is no single build's index. The
# build flags are Periphery 3.x's own plus the compilation cache off: a compile
# the cache serves writes no index unit, leaving the unit an earlier compile
# wrote — after a revert, a cached scan reported 27 findings in code that no
# longer existed (Xcode 27.1). Each scheme is built for testing, so the one
# index serves both views — the full scan, and the production scan with every
# target only tests reach excluded — and the bundle written from it holds both
# and that index's declaration sites. With the Ubuntu SDK installed,
# Tools/dead-code-linux.sh writes the Linux bundle beside it and the report on
# stdout combines the two, as .github/workflows/dead-code.yml does; without it
# the report covers macOS alone and names what installs the rest. The built
# apps are unregistered from Launch Services on the way out, whatever the
# outcome, so a scan's build never wins the version election.
PERIPHERY_DERIVED_DATA := $(DERIVED_DATA_ROOT)/Periphery
PERIPHERY_SCHEMES      := Kernova KernovaMacOSAgent KernovaRelaunchHelper KernovaCLI KernovaBench
PERIPHERY_INDEX_STORE  := $(PERIPHERY_DERIVED_DATA)/Index.noindex/DataStore
DEAD_CODE_BUNDLE       := $(PERIPHERY_DERIVED_DATA)/Report/macos
DEAD_CODE_LINUX_BUNDLE := $(PERIPHERY_DERIVED_DATA)/Report/linux

dead-code: ## Scan for unused code with Periphery on macOS and, once `make ubuntu-sdk` has run, Linux: the combined scan CI runs (builds every scheme first; minutes)
	$(LOCKED_TWIN)

locked-dead-code:
	@trap "Tools/build-arenas.sh unregister '$(PERIPHERY_DERIVED_DATA)/Build/Products' >&2" EXIT; \
	periphery=$$(Tools/install-periphery.sh) || exit 1; \
	indexutil=$$(Tools/install-periphery.sh --indexutil-export) || exit 1; \
	dead_code=$$(Tools/install-dead-code-tool.sh dead-code) || exit 1; \
	sources=$$(Tools/install-dead-code-tool.sh dead-code-sources) || exit 1; \
	raw=$(PERIPHERY_DERIVED_DATA)/Report/raw; \
	mkdir -p "$$raw" || exit 1; \
	"$$dead_code" test-only-targets --project $(PROJECT) > "$$raw/test-only-targets.txt" || exit 1; \
	for scheme in $(PERIPHERY_SCHEMES); do \
		xcodebuild $(XCODEBUILD_PROJECT_FLAGS) -scheme "$$scheme" -destination '$(DESTINATION)' \
			-derivedDataPath $(PERIPHERY_DERIVED_DATA) -parallelizeTargets -quiet \
			build-for-testing \
			CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT=dwarf \
			COMPILER_INDEX_STORE_ENABLE=YES INDEX_ENABLE_DATA_STORE=YES \
			COMPILATION_CACHE_ENABLE_CACHING=NO >&2 || exit 1; \
	done; \
	"$$sources" bundle --root '$(CURDIR)' --base '$(CURDIR)' --periphery "$$periphery" \
		--store $(PERIPHERY_INDEX_STORE) --indexutil-export "$$indexutil" \
		--test-only-targets "$$raw/test-only-targets.txt" --output $(DEAD_CODE_BUNDLE) \
		-- --project $(PROJECT) --schemes $(PERIPHERY_SCHEMES) || exit 1; \
	missing=$$(bash -c '. Tools/lib/linux-swift.sh && ubuntu_sdk_missing "$$(pinned_swift_version)"'); \
	if [ -z "$$missing" ]; then \
		Tools/dead-code-linux.sh "$$raw/test-only-targets.txt" $(DEAD_CODE_LINUX_BUNDLE) >&2 && \
		"$$dead_code" report --platform macos=$(DEAD_CODE_BUNDLE) --platform linux=$(DEAD_CODE_LINUX_BUNDLE); \
	else \
		"$$dead_code" report --platform macos=$(DEAD_CODE_BUNDLE) \
			--remedy "The Linux half builds with $$missing, which is not installed: run \`make ubuntu-sdk\` once, and \`make dead-code\` then scans both."; \
	fi

dead-code-targets: ## Print the targets only tests reach, which the dead-code scan's production view excludes
	@dead_code=$$(Tools/install-dead-code-tool.sh dead-code) && "$$dead_code" test-only-targets --project $(PROJECT)

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
