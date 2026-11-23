# Kernova build & test invocations.
#
# These targets own the `xcodebuild` invocations, through Tools/xcodebuild.sh
# with the flags Tools/lib/xcodebuild-flags.sh gives them — they are not the
# obvious ones, so never hand-write one. Every build lands in this checkout's
# DerivedData/. Inside Xcode, just use the IDE (CMD-B / CMD-U), which builds
# in Xcode's own DerivedData folder; this Makefile is for terminal, CI, and
# tooling use.

RESULT_BUNDLE := artifacts/TestResults.xcresult

ifneq ($(strip $(CI)),)
RESULT_BUNDLE_FLAG := -resultBundlePath $(RESULT_BUNDLE)
endif

# Override on the command line to build in Release, e.g.
# `make build CONFIGURATION=Release`. `make test` tests Debug only.
CONFIGURATION ?= Debug

XCODEBUILD = Tools/xcodebuild.sh '$(CONFIGURATION)'

# swift-format ships with the Xcode toolchain (Xcode 26+); use xcrun so the
# command resolves the same binary in CI and locally without a brew install.
SWIFT_FORMAT := xcrun swift-format

SWIFT_SOURCE_DIRS := $(shell bash -c '. Tools/lib/swift-roots.sh && swift_roots')

.DEFAULT_GOAL := help
.PHONY: help build build-for-testing test test-linux attest test-without-building test-suite test-unhosted test-unhosted-tsan swift-toolchain linux-build clean format lint dead-code prune-worktrees

# Generated from the `## ` annotation on each target line below — annotate new
# targets there and this listing (and its ordering) follows automatically.
help:
	@printf 'Kernova build targets:\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-22s %s\n", $$1, $$2}'
	@printf '\n'
	@printf '  make test-suite requires SUITE=<Target/Suite>, e.g. SUITE=KernovaVirtualizationTests/ConfigurationBuilderTests or SUITE=KernovaCoreTests/VMConfigurationTests\n'
	@printf '  Append CONFIGURATION=Release to build or test-without-building in Release (default: Debug); make test runs Debug only\n'
	@printf '  Prefix CI=1 to build/test with the CI-only settings (a result bundle in artifacts/; a compilation cache store of its own in DerivedData/, rolled over every build)\n'

build: ## Build the app for macOS
	$(XCODEBUILD) build
	@Tools/built-app.sh '$(CONFIGURATION)'

build-for-testing: ## Compile the app and test bundles without running them, then check the built app's weak links
	$(XCODEBUILD) build-for-testing
	@Tools/built-app.sh --check-weak-links '$(CONFIGURATION)'

clean: ## Remove this checkout's builds: its DerivedData/
	rm -rf DerivedData

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
	$(XCODEBUILD) test-without-building $(RESULT_BUNDLE_FLAG)

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
# requirement no longer admits them; this rewrites the tracked pin file, the
# Xcode workspace's, which every top-level package takes.
.PHONY: resolve-packages
resolve-packages: ## Re-resolve the tracked Package.resolved after a package requirement changes
	Tools/xcodebuild.sh -resolvePackageDependencies

swift-toolchain: ## Install swiftly, the swift.org toolchain .swift-version pins, and its Static Linux SDK
	@Tools/install-swift-toolchain.sh >/dev/null

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
	$(XCODEBUILD) test -only-testing:$(SUITE)

format: ## Rewrite Swift sources in place via swift-format
	@test -n '$(strip $(SWIFT_SOURCE_DIRS))' || { echo 'No tracked Swift sources found — not a git checkout?' >&2; exit 1; }
	$(SWIFT_FORMAT) format --in-place --recursive $(SWIFT_SOURCE_DIRS)

lint: ## Run Tools/lint.sh: shellcheck, the checks, swift-format --strict and the prune-worktrees fixture test; a passing run is recorded for `make attest`
	@Tools/attest.sh record lint

dead-code: ## List the code nothing uses, then the code only tests use, with the Periphery on PATH (builds the app first; minutes)
	@Tools/build-lock.sh Tools/dead-code.sh

prune-worktrees: ## Remove the worktrees under .claude/worktrees whose work is merged, and the Launch Services records of builds that are gone; Tools/prune-worktrees.sh -n prints what it would do
	@Tools/prune-worktrees.sh
