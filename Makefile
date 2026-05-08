# Kernova build & test invocations.
#
# These targets wrap the canonical `xcodebuild` calls documented in
# .claude/CLAUDE.md. Inside Xcode, just use the IDE (CMD-B / CMD-U); this
# Makefile is for terminal, CI, and tooling use.

PROJECT      := Kernova.xcodeproj
SCHEME       := Kernova
DESTINATION  := platform=macOS
DERIVED_DATA := DerivedData

XCODEBUILD_FLAGS := -project $(PROJECT) \
                    -scheme $(SCHEME) \
                    -destination '$(DESTINATION)' \
                    -derivedDataPath $(DERIVED_DATA)

# swift-format ships with the Xcode toolchain (Xcode 26+); use xcrun so the
# command resolves the same binary in CI and locally without a brew install.
SWIFT_FORMAT      := xcrun swift-format
SWIFT_SOURCE_DIRS := Kernova KernovaTests KernovaGuestAgent KernovaGuestAgentTests KernovaProtocol KernovaRelaunchHelper

.DEFAULT_GOAL := help
.PHONY: help build test test-suite clean format lint

help:
	@printf 'Kernova build targets:\n\n'
	@printf '  make build               Build the app for macOS\n'
	@printf '  make test                Run the full test suite\n'
	@printf '  make test-suite SUITE=X  Run a single test suite (Target/Suite form)\n'
	@printf '                           (e.g. SUITE=KernovaTests/VMConfigurationTests)\n'
	@printf '  make format              Rewrite Swift sources in place via swift-format\n'
	@printf '  make lint                Check Swift sources with swift-format (--strict)\n'
	@printf '  make clean               Remove the DerivedData directory\n'

build:
	xcodebuild $(XCODEBUILD_FLAGS) build

test:
	xcodebuild $(XCODEBUILD_FLAGS) test

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

clean:
	rm -rf $(DERIVED_DATA)
