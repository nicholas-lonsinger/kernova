# Kernova build & test invocations.
#
# These targets wrap the canonical `xcodebuild` calls documented in
# CLAUDE.md. Inside Xcode, just use the IDE (CMD-B / CMD-U); this
# Makefile is for terminal, CI, and tooling use.

PROJECT      := Kernova.xcodeproj
SCHEME       := Kernova
DESTINATION  := platform=macOS

# Xcode's Locations -> Derived Data "Relative" setting doesn't write straight
# into DerivedData/ — it nests a subfolder named after the project
# (DerivedData/Kernova/, whichever scheme is built).
#
# When this machine's Xcode is set to Relative (the IDECustomDerivedDataLocation
# default is exactly "DerivedData") and the workspace carries no per-user
# derived-data override, OMIT -derivedDataPath: a flag-less xcodebuild reads the
# same IDE setting and computes the identical build arena as the GUI — same
# nested location AND same arena identity — so terminal and Xcode builds share
# incremental state (switching is a null build). Passing -derivedDataPath, even
# with the identical path, records a different arena identity in the build
# description, and every CLI<->GUI switch then re-runs the whole compile graph.
#
# On machines without the Relative setting (CI, fresh clones), fall back to the
# explicit flag so output still lands deterministically in the worktree instead
# of the per-path-hashed ~/Library location. A per-user override set via
# Xcode's File > Project Settings… also disables the omission: xcodebuild would
# follow it wherever it points, so the explicit flag is the safer default.
DERIVED_DATA_ROOT := DerivedData
DERIVED_DATA      := $(DERIVED_DATA_ROOT)/$(basename $(PROJECT))
GLOBAL_DD_PREF    := $(shell defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null)
USER_DD_OVERRIDE  := $(shell plutil -extract DerivedDataCustomLocation raw $(PROJECT)/project.xcworkspace/xcuserdata/$(USER).xcuserdatad/WorkspaceSettings.xcsettings -o - 2>/dev/null)
ifeq ($(GLOBAL_DD_PREF)$(USER_DD_OVERRIDE),DerivedData)
DERIVED_DATA_FLAG :=
else
DERIVED_DATA_FLAG := -derivedDataPath $(DERIVED_DATA)
endif

# Build configuration, passed explicitly rather than relying on the scheme's
# per-action default (Debug). Override on the command line to build/test in
# Release, e.g. `make build CONFIGURATION=Release`.
CONFIGURATION ?= Debug

XCODEBUILD_FLAGS := -project $(PROJECT) \
                    -scheme $(SCHEME) \
                    -destination '$(DESTINATION)' \
                    $(DERIVED_DATA_FLAG) \
                    -configuration $(CONFIGURATION)

# swift-format ships with the Xcode toolchain (Xcode 26+); use xcrun so the
# command resolves the same binary in CI and locally without a brew install.
SWIFT_FORMAT      := xcrun swift-format
SWIFT_SOURCE_DIRS := Kernova KernovaTests KernovaMacOSAgent KernovaMacOSAgentTests KernovaKit KernovaQuickLook KernovaRelaunchHelper KernovaMacOSAgentFileProvider KernovaFileProvider

.DEFAULT_GOAL := help
.PHONY: help build test test-suite test-package clean format lint install-hooks check-hooks bootstrap doctor ghosts clean-ghosts fp-reset ls-reset

help:
	@printf 'Kernova build targets:\n\n'
	@printf '  make build               Build the app for macOS\n'
	@printf '  make test                Run the full test suite (all three test targets via Kernova.xctestplan)\n'
	@printf '  make test-suite SUITE=X  Run a single test suite (Target/Suite form)\n'
	@printf '                           (e.g. SUITE=KernovaTests/VMConfigurationTests)\n'
	@printf '  make test-package        Run only the KernovaKit SwiftPM package tests\n'
	@printf '  make format              Rewrite Swift sources in place via swift-format\n'
	@printf '  make lint                Check Swift sources with swift-format (--strict)\n'
	@printf '  make install-hooks       Point git at .githooks/ (runs lint on pre-push)\n'
	@printf '  make bootstrap           Derive your signing team into Config/Local.xcconfig (auto-run by build/test)\n'
	@printf '  make doctor              Check the local toolchain (macOS, Xcode, Swift, swift-format, hooks)\n'
	@printf '  make ghosts              Report stale/competing Kernova Launch Services, process, and worktree registrations\n'
	@printf '  make clean-ghosts        Same as ghosts, but also unregisters/kills/prunes/evicts what it finds\n'
	@printf '  make fp-reset            Restart fileproviderd to clear stale Kernova File Provider bindings\n'
	@printf '  make ls-reset            Clear legacy com.kernova.app ghost Launch Services registrations\n'
	@printf '  make clean               Remove the DerivedData directory\n'
	@printf '\n'
	@printf '  Append CONFIGURATION=Release to build/test in Release (default: Debug)\n'

build: check-hooks bootstrap
	xcodebuild $(XCODEBUILD_FLAGS) build

test: check-hooks bootstrap
	xcodebuild $(XCODEBUILD_FLAGS) test

# `xcrun` so the toolchain matches the one selected via `xcode-select`
# (same rationale as the `xcrun swift-format` invocation above).
test-package:
	xcrun swift test --package-path KernovaKit

test-suite: bootstrap
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

# Derives this developer's signing team from their own certificate into the
# gitignored Config/Local.xcconfig (see Config/Base.xcconfig) — what makes a
# fresh clone build and sign with *your* team rather than a hardcoded one
# (#476). A prerequisite of build/test rather than a separate manual step, so
# a fresh clone's first `make build` just works; Tools/bootstrap-team.sh is
# idempotent (no-ops once Config/Local.xcconfig has a value), so this is cheap
# on every subsequent build. Re-derive with `Tools/bootstrap-team.sh --force`.
bootstrap:
	@Tools/bootstrap-team.sh

# Environment sanity check: verifies the local toolchain (macOS, Xcode, Swift,
# swift-format) and repo setup (git hooks) match what Kernova needs to build,
# lint, and push. A starting point — extend Tools/doctor.sh with more checks
# over time. Exits non-zero if any required check fails, so it's CI-usable too.
doctor:
	@Tools/doctor.sh

# Diagnoses ghost Launch Services registrations, orphaned processes, and
# prunable git worktrees left behind when a worktree is torn down by hand
# instead of through Claude Code's ExitWorktree unregister hook — plus LIVE
# on-disk Kernova.app copies (Trash, DerivedData) that outrank the installed
# /Applications copy in the LaunchServices/PluginKit CFBundleVersion election
# (#454). `ghosts` only reports; `clean-ghosts` also unregisters/kills/prunes,
# and offers to evict (trash) a competing copy it finds.
ghosts:
	@Tools/ghosts.sh

clean-ghosts:
	@Tools/ghosts.sh --fix

# Restarts the File Provider daemon to clear stale Kernova domain/extension
# bindings — e.g. after a rebuild leaves fileproviderd pointing at a deleted or
# moved extension binary (Copy to Mac then beeps because the extension can't
# launch), or a domain wedged in a dead-end state. Kept separate from
# clean-ghosts and opt-in because it briefly interrupts ALL File Providers
# (iCloud Drive reconnects within seconds). macOS 26's fileproviderctl has no
# domain-remove command; the app self-heals a dead domain on next launch.
fp-reset:
	@printf 'Restarting fileproviderd to clear stale Kernova File Provider bindings...\n'
	@printf '(briefly interrupts all File Providers; iCloud Drive reconnects in a few seconds)\n'
	@killall fileproviderd 2>/dev/null && printf 'fileproviderd restarted.\n' || printf 'fileproviderd was not running; it will start on demand.\n'

# Clears ghost Launch Services registrations left under the legacy
# pre-#471-rename `com.kernova.app` identifier — a gap `clean-ghosts` can't
# see, since Tools/ghosts.sh's Launch Services check only pattern-matches the
# current `app.kernova` identifier. Kept as its own target (rather than folded
# into ghosts.sh) until the legacy-identifier era is retired; see
# Tools/ls-reset.sh for why this isn't the system-wide rebuild its name might
# suggest (`-kill` no longer exists in lsregister, and turns out unnecessary).
ls-reset:
	@Tools/ls-reset.sh

clean:
	rm -rf $(DERIVED_DATA_ROOT)
