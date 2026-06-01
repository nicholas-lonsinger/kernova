# Kernova build & test invocations.
#
# These targets wrap the canonical `xcodebuild` calls documented in
# CLAUDE.md. Inside Xcode, just use the IDE (CMD-B / CMD-U); this
# Makefile is for terminal, CI, and tooling use.

PROJECT      := Kernova.xcodeproj
SCHEME       := Kernova
DESTINATION  := platform=macOS
DERIVED_DATA := DerivedData

# Build configuration, passed explicitly rather than relying on the scheme's
# per-action default (Debug). Override on the command line to build/test in
# Release, e.g. `make build CONFIGURATION=Release`.
CONFIGURATION ?= Debug

XCODEBUILD_FLAGS := -project $(PROJECT) \
                    -scheme $(SCHEME) \
                    -destination '$(DESTINATION)' \
                    -derivedDataPath $(DERIVED_DATA) \
                    -configuration $(CONFIGURATION)

# swift-format ships with the Xcode toolchain (Xcode 26+); use xcrun so the
# command resolves the same binary in CI and locally without a brew install.
SWIFT_FORMAT      := xcrun swift-format
SWIFT_SOURCE_DIRS := Kernova KernovaTests KernovaGuestAgent KernovaGuestAgentTests KernovaProtocol KernovaRelaunchHelper

.DEFAULT_GOAL := help
.PHONY: help build test test-suite test-package clean format lint install-hooks check-hooks

help:
	@printf 'Kernova build targets:\n\n'
	@printf '  make build               Build the app for macOS\n'
	@printf '  make test                Run the full test suite (all three test targets via Kernova.xctestplan)\n'
	@printf '  make test-suite SUITE=X  Run a single test suite (Target/Suite form)\n'
	@printf '                           (e.g. SUITE=KernovaTests/VMConfigurationTests)\n'
	@printf '  make test-package        Run only the KernovaProtocol SwiftPM package tests\n'
	@printf '  make format              Rewrite Swift sources in place via swift-format\n'
	@printf '  make lint                Check Swift sources with swift-format (--strict)\n'
	@printf '  make install-hooks       Point git at .githooks/ (runs lint on pre-push)\n'
	@printf '  make clean               Remove the DerivedData directory\n'
	@printf '\n'
	@printf '  Append CONFIGURATION=Release to build/test in Release (default: Debug)\n'

build: check-hooks
	xcodebuild $(XCODEBUILD_FLAGS) build

test: check-hooks
	xcodebuild $(XCODEBUILD_FLAGS) test

# `xcrun` so the toolchain matches the one selected via `xcode-select`
# (same rationale as the `xcrun swift-format` invocation above).
test-package:
	xcrun swift test --package-path KernovaProtocol

test-suite:
	@if [ -z "$(SUITE)" ]; then \
		echo 'Usage: make test-suite SUITE=<Target/Suite>' >&2; \
		echo 'Example: make test-suite SUITE=KernovaTests/VMConfigurationTests' >&2; \
		exit 2; \
	fi
	xcodebuild $(XCODEBUILD_FLAGS) test -only-testing:$(SUITE)

format:
	$(SWIFT_FORMAT) format --in-place --recursive $(SWIFT_SOURCE_DIRS)

lint:
	$(SWIFT_FORMAT) lint --strict --recursive $(SWIFT_SOURCE_DIRS)

# One-time per clone: point this repo's git at the checked-in hooks so
# `.githooks/pre-push` runs `make lint` before each push. Per-repo config
# (no `--global`); bypass an individual push with `git push --no-verify`.
install-hooks:
	git config core.hooksPath .githooks
	@echo 'Hooks installed. Pre-push will now run `make lint`.'

# Silent when the hook is wired up; otherwise a one-line nudge. Runs as a
# prerequisite of `build` and `test` so contributors who skipped the
# install step see the reminder on their first build instead of only when
# CI fails on their PR.
check-hooks:
	@hp=$$(git config --get core.hooksPath 2>/dev/null || true); \
	if [ "$$hp" != ".githooks" ]; then \
		printf 'Note: pre-push lint hook is not installed. Run `make install-hooks` (one-time per clone) to catch swift-format issues locally.\n' >&2; \
	fi

clean:
	rm -rf $(DERIVED_DATA)
