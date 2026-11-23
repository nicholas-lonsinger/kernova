# Kernova build & test invocations.
#
# These targets own the `xcodebuild` invocations, through Tools/xcodebuild.sh
# with the flags Tools/lib/xcodebuild-flags.sh gives them — they are not the
# obvious ones, so never hand-write one. Every build lands in this checkout's
# DerivedData/. Inside Xcode, just use the IDE (CMD-B / CMD-U), which builds
# in Xcode's own DerivedData folder; this Makefile is for terminal, CI, and
# tooling use.

XCODEBUILD_LIB         := . Tools/lib/xcodebuild-flags.sh
PROJECT                := $(shell bash -c '$(XCODEBUILD_LIB) && echo "$$kernova_project"')
SCHEME                 := $(shell bash -c '$(XCODEBUILD_LIB) && echo "$$kernova_scheme"')
DESTINATION            := $(shell bash -c '$(XCODEBUILD_LIB) && echo "$$kernova_destination"')
DERIVED_DATA           := $(shell bash -c '$(XCODEBUILD_LIB) && echo "$$kernova_derived_data"')
INDEX_DERIVED_DATA     := $(shell bash -c '$(XCODEBUILD_LIB) && echo "$$kernova_index_derived_data"')
DEAD_CODE_DERIVED_DATA := $(shell bash -c '$(XCODEBUILD_LIB) && echo "$$kernova_dead_code_derived_data"')
RESULT_BUNDLE          := artifacts/TestResults.xcresult

ifneq ($(strip $(CI)),)
RESULT_BUNDLE_FLAG := -resultBundlePath $(RESULT_BUNDLE)
endif

# Override on the command line to build in Release, e.g.
# `make build CONFIGURATION=Release`. `make test` tests Debug only.
CONFIGURATION ?= Debug

XCODEBUILD               = Tools/xcodebuild.sh '$(CONFIGURATION)'
XCODEBUILD_PROJECT_FLAGS := $(shell bash -c '$(XCODEBUILD_LIB) && xcodebuild_project_flags')

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
.PHONY: help build locked-build build-for-testing locked-build-for-testing test test-linux attest test-without-building test-suite test-unhosted test-unhosted-tsan swift-toolchain ubuntu-sdk linux-build clean locked-clean format lint install-hooks install-lsp index locked-index dead-code locked-dead-code dead-code-targets ghosts clean-ghosts

# Generated from the `## ` annotation on each target line below — annotate new
# targets there and this listing (and its ordering) follows automatically.
help:
	@printf 'Kernova build targets:\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-22s %s\n", $$1, $$2}'
	@printf '\n'
	@printf '  make test-suite requires SUITE=<Target/Suite>, e.g. SUITE=KernovaVirtualizationTests/ConfigurationBuilderTests or SUITE=KernovaCoreTests/VMConfigurationTests\n'
	@printf '  Append CONFIGURATION=Release to build or test-without-building in Release (default: Debug); make test runs Debug only\n'
	@printf '  Prefix CI=1 to build/test with the CI-only settings (a result bundle in artifacts/; a compilation cache store of its own in DerivedData/, rolled over every build)\n'

install-hooks: ## Point git at .githooks/, whose post-checkout sets up each new worktree (Tools/worktree-setup.sh)
	git config core.hooksPath .githooks

# One-time per checkout: sourcekit-lsp reads compiler flags and the index from
# a buildServer.json that xcode-build-server writes, naming the build `make
# index` makes, so editors and Claude Code's Swift language server resolve
# imports and symbols across the project. The config names an absolute build
# root — every checkout writes its own, and .githooks/post-checkout writes a
# new worktree's when the tool is already installed.
install-lsp: ## Install xcode-build-server and write this checkout's buildServer.json
	@command -v xcode-build-server >/dev/null || brew install xcode-build-server
	@Tools/lsp-config.sh '$(PROJECT)' '$(SCHEME)'

# The build the language server reads: uncached and unmapped, so every compile
# writes an index unit naming the real file, which no `make` build does
# (Tools/lib/xcodebuild-flags.sh). `Tools/build-arenas.sh build` unregisters
# its bundles once it has exited, so this build never wins the version
# election.
index: ## Build this checkout's index for the Swift language server (minutes the first time, seconds after); rerun after a change for cross-file results
	$(LOCKED_TWIN)

locked-index:
	@exec Tools/build-arenas.sh build '$(INDEX_DERIVED_DATA)/Build/Products' \
		xcodebuild $(XCODEBUILD_PROJECT_FLAGS) -scheme $(SCHEME) -destination '$(DESTINATION)' -configuration Debug \
		-derivedDataPath $(INDEX_DERIVED_DATA) -enableCodeCoverage NO build-for-testing \
		CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=YES INDEX_ENABLE_DATA_STORE=YES \
		COMPILATION_CACHE_ENABLE_CACHING=NO

build: ## Build the app for macOS
	$(LOCKED_TWIN)

locked-build:
	$(XCODEBUILD) build
	@Tools/built-app.sh '$(CONFIGURATION)'

build-for-testing: ## Compile the app and test bundles without running them, then check the built app's weak links
	$(LOCKED_TWIN)

locked-build-for-testing:
	$(XCODEBUILD) build-for-testing
	@Tools/built-app.sh --check-weak-links '$(CONFIGURATION)'

clean: ## Remove this checkout's builds: its DerivedData/
	$(LOCKED_TWIN)

locked-clean:
	@Tools/build-arenas.sh clean

test: ## Run the full test suite (every test target in Kernova.xctestplan) in Debug, then check the built app's weak links; a passing run is recorded for `make attest`
	@test '$(CONFIGURATION)' = Debug || { echo 'make test runs Debug only, the build its record covers; build-for-testing and test-without-building take CONFIGURATION=$(CONFIGURATION)' >&2; exit 2; }
	Tools/attest.sh record test

test-linux: ## Run KernovaKit's Linux tests in Apple's container, as CI's Linux job does; a passing run is recorded for `make attest`
	@Tools/attest.sh record test-linux

attest: ## Post the `Commit Attestation` status on the pushed HEAD, reusing a passing `make lint`, `make test-linux` and `make test` of the same inputs or running them
	@Tools/attest.sh

# The `rm -rf` fires only when RESULT_BUNDLE_FLAG is set (CI): xcodebuild
# refuses a -resultBundlePath that already exists, and outside CI this target
# passes no such flag and must not touch artifacts/.
test-without-building: ## Run the test plan against an existing build-for-testing product
	@test -z '$(RESULT_BUNDLE_FLAG)' || rm -rf '$(RESULT_BUNDLE)'
	$(LOCKED) $(XCODEBUILD) test-without-building $(RESULT_BUNDLE_FLAG)

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
	$(LOCKED) xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED_DATA) -resolvePackageDependencies
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

test-suite: ## Run a single test suite (SUITE=<Target/Suite>; see below)
	@if [ -z "$(SUITE)" ]; then \
		echo 'Usage: make test-suite SUITE=<Target/Suite>' >&2; \
		echo 'Example: make test-suite SUITE=KernovaCoreTests/VMConfigurationTests' >&2; \
		exit 2; \
	fi
	$(LOCKED) $(XCODEBUILD) test -only-testing:$(SUITE)

format: ## Rewrite Swift sources in place via swift-format
	@test -n '$(strip $(SWIFT_SOURCE_DIRS))' || { echo 'No tracked Swift sources found — not a git checkout?' >&2; exit 1; }
	$(SWIFT_FORMAT) format --in-place --recursive $(SWIFT_SOURCE_DIRS)

lint: ## Run Tools/lint.sh: shellcheck, the checks, swift-format --strict and the worktree and ghost suites; a passing run is recorded for `make attest`
	@Tools/attest.sh record lint

# The scan and its arena are Tools/dead-code.sh's.
dead-code: ## Scan for unused code with Periphery on macOS and, once `make ubuntu-sdk` has run, Linux: the combined scan CI runs (builds every scheme first; minutes)
	$(LOCKED_TWIN)

locked-dead-code:
	@exec Tools/build-arenas.sh build '$(DEAD_CODE_DERIVED_DATA)/Build/Products' Tools/dead-code.sh

dead-code-targets: ## Print the targets only tests reach, which the dead-code scan's production view excludes
	@dead_code=$$(Tools/install-dead-code-tool.sh dead-code) && "$$dead_code" test-only-targets --project $(PROJECT)

ghosts: ## Report stale/competing Kernova Launch Services registrations, processes, worktrees, and build arenas
	@Tools/ghosts.sh

clean-ghosts: ## Same as ghosts, but also unregisters/kills/prunes/trashes/removes/evicts what it finds
	@Tools/ghosts.sh --fix
