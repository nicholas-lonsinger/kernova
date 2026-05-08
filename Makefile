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

.DEFAULT_GOAL := help
.PHONY: help build test test-suite clean

help:
	@printf 'Kernova build targets:\n\n'
	@printf '  make build               Build the app for macOS\n'
	@printf '  make test                Run the full test suite\n'
	@printf '  make test-suite SUITE=X  Run a single test suite\n'
	@printf '                           (e.g. SUITE=VMConfigurationTests)\n'
	@printf '  make clean               Remove the DerivedData directory\n'

build:
	xcodebuild $(XCODEBUILD_FLAGS) build

test:
	xcodebuild $(XCODEBUILD_FLAGS) test

test-suite:
	@if [ -z "$(SUITE)" ]; then \
		echo 'Usage: make test-suite SUITE=<TestSuiteName>' >&2; \
		exit 2; \
	fi
	xcodebuild $(XCODEBUILD_FLAGS) test -only-testing:KernovaTests/$(SUITE)

clean:
	rm -rf $(DERIVED_DATA)
