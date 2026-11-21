#!/usr/bin/env bash
# Fixture tests for Tools/install-linux-guest-agent.sh's cache entry name, in a
# scratch repository holding the script, Tools/lib and a small KernovaKit, with
# stubs for the swift.org toolchain and SwiftPM's package description: which
# changes name a new entry — to what the build reads, as files on disk, or to
# how it runs — and which leave it, a target outside the agent and a second
# checkout path among them.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_CACHE_HOME="$tmp/home/.cache" SWIFTLY_HOME_DIR="$tmp/swiftly"
unset KERNOVA_AGENT_FAULT KERNOVA_SWIFT_SDKS_PATH CONFIGURATION
mkdir -p "$HOME"

# shellcheck source=../lib/static-linux-sdk.sh
. "$ROOT/Tools/lib/static-linux-sdk.sh"
version=$(pinned_swift_version)
sdk=$(static_sdk_id "$version")

# The stubs: a `swift` answers -print-target-info with its toolchain file,
# `sdk list` with the SDK, and `package … describe` with $tmp/description.
# swiftly runs the pinned one, whose toolchain is $tmp/toolchain; on macOS the
# `swift` on PATH is Xcode's, with a toolchain of its own, and xcrun names an
# SDK build. The installed toolchain and SDK are empty directories where the
# libraries look.
mkdir -p "$tmp/bin" "$tmp/pinned" "$SWIFTLY_HOME_DIR/bin" \
    "$HOME/Library/Developer/Toolchains/swift-$version-RELEASE.xctoolchain" \
    "$HOME/Library/org.swift.swiftpm/swift-sdks/$sdk.artifactbundle"
stub_swift() { # <path> <toolchain file>
    cat >"$1" <<EOF
#!/bin/sh
for argument in "\$@"; do
    case "\$argument" in
        -print-target-info) exec cat "$2" ;;
        describe) exec cat "$tmp/description" ;;
        sdk) echo "$sdk"; exit 0 ;;
    esac
done
exit 1
EOF
    chmod +x "$1"
}
stub_swift "$tmp/pinned/swift" "$tmp/toolchain"
if [ "$(uname -s)" = Darwin ]; then
    stub_swift "$tmp/bin/swift" "$tmp/xcode-toolchain"
    printf '  "compilerVersion": "Xcode",\n' >"$tmp/xcode-toolchain"
else
    cp "$tmp/pinned/swift" "$tmp/bin/swift"
fi
printf '#!/bin/sh\n[ "$1" = run ] && [ "$2" = swift ] || exit 1\nshift 2\nexec "%s" "$@"\n' "$tmp/pinned/swift" \
    >"$SWIFTLY_HOME_DIR/bin/swiftly"
printf '#!/bin/sh\necho 1A1\n' >"$tmp/bin/xcrun"
chmod +x "$SWIFTLY_HOME_DIR/bin/swiftly" "$tmp/bin/xcrun"
export PATH="$tmp/bin:$PATH"
toolchain() { printf '  "compilerVersion": "%s",\n' "$1" >"$tmp/toolchain"; }
toolchain 'Swift 1'

# describe <C's product memberships> — kernova-agent is A's, which B is in; C
# is another product's.
describe() {
    cat >"$tmp/description" <<EOF
{
  "dependencies": [{"identity": "p", "type": "sourceControl", "url": "https://example.com/p.git"}],
  "products": [
    {"name": "kernova-agent", "targets": ["A"], "type": {"executable": null}},
    {"name": "other", "targets": ["C"], "type": {"executable": null}}
  ],
  "targets": [
    {"name": "A", "path": "Sources/A", "product_memberships": ["kernova-agent"], "target_dependencies": ["B"]},
    {"name": "B", "path": "Sources/B", "product_memberships": ["kernova-agent"]},
    {"name": "C", "path": "Sources/C", "product_memberships": [$1]}
  ]
}
EOF
}
describe '"other"'

new_repo() { # <dir>
    local pins="$1/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
    mkdir -p "$1/Tools/lib" "$1/KernovaKit/Sources/A/sub" "$1/KernovaKit/Sources/B" "$1/KernovaKit/Sources/C" \
        "$1/Kernova" "$pins" &&
        cp "$ROOT/Tools/install-linux-guest-agent.sh" "$1/Tools/" && cp "$ROOT"/Tools/lib/*.sh "$1/Tools/lib/" &&
        cp "$ROOT/.swift-version" "$1/" && echo manifest >"$1/KernovaKit/Package.swift" &&
        echo pins >"$pins/Package.resolved" && echo a >"$1/KernovaKit/Sources/A/a.swift" &&
        echo a2 >"$1/KernovaKit/Sources/A/sub/a2.swift" && echo b >"$1/KernovaKit/Sources/B/b.swift" &&
        echo c >"$1/KernovaKit/Sources/C/c.swift" && echo app >"$1/Kernova/App.swift"
}
repo="$tmp/repo"
new_repo "$repo" || exit 1

key() { "$repo/Tools/install-linux-guest-agent.sh" --path 2>"$tmp/err"; }
base=$(key) || { fail "the name: --path failed: $(cat "$tmp/err")"; base=''; }
case "$base" in
    "$XDG_CACHE_HOME"/kernova-dev/kernova-agent-*/kernova-agent | "$HOME"/Library/Caches/kernova-dev/kernova-agent-*/kernova-agent) pass ;;
    *) fail "the name: '$base' is not kernova-agent-<digits>/kernova-agent in the cache" ;;
esac
check() { # <failure> <command>...
    local failure=$1
    shift
    if "$@"; then pass; else fail "$failure"; fi
}
check 'a second lookup named another entry' [ "$(key)" = "$base" ]

# changes <what> <command>... --restore <command>... — the change names
# another entry, and undoing it names this one again.
changes() {
    local what=$1 changed
    shift
    local change=() restore=()
    while [ "$1" != --restore ]; do change+=("$1"); shift; done
    shift
    restore=("$@")
    "${change[@]}"
    changed=$(key)
    "${restore[@]}"
    if [ "$changed" = "$base" ]; then
        fail "unchanged when $what"
    elif [ "$(key)" != "$base" ]; then
        fail "not restored when $what was undone"
    else
        pass
    fi
}
# keeps <what> <command>... --restore <command>... — the change names this entry.
keeps() {
    local what=$1 changed
    shift
    local change=() restore=()
    while [ "$1" != --restore ]; do change+=("$1"); shift; done
    shift
    restore=("$@")
    "${change[@]}"
    changed=$(key)
    "${restore[@]}"
    if [ "$changed" != "$base" ]; then fail "changed when $what"; else pass; fi
}
write() { printf '%s\n' "$2" >"$1"; }
append() { printf '%s\n' "$2" >>"$1"; }
undo_append() { # <file> — drops the last line
    local kept
    kept=$(sed '$d' "$1") && printf '%s\n' "$kept" >"$1"
}
sources="$repo/KernovaKit/Sources"
pins="$repo/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

changes "an agent target's source changes" write "$sources/A/a.swift" A --restore write "$sources/A/a.swift" a
changes "a nested source changes" write "$sources/A/sub/a2.swift" A2 --restore write "$sources/A/sub/a2.swift" a2
changes "a dependency target's source changes" write "$sources/B/b.swift" B --restore write "$sources/B/b.swift" b
changes 'a source file is added' write "$sources/B/new.swift" n --restore rm "$sources/B/new.swift"
changes 'the manifest changes' write "$repo/KernovaKit/Package.swift" edited --restore write "$repo/KernovaKit/Package.swift" manifest
changes 'the pins change' write "$pins" bumped --restore write "$pins" pins
changes 'the installer changes' append "$repo/Tools/install-linux-guest-agent.sh" '# edited' \
    --restore undo_append "$repo/Tools/install-linux-guest-agent.sh"
changes 'a library changes' append "$repo/Tools/lib/linux-swift.sh" '# edited' \
    --restore undo_append "$repo/Tools/lib/linux-swift.sh"
changes 'the compiler changes' toolchain 'Swift 2' --restore toolchain 'Swift 1'
fault() { KERNOVA_AGENT_FAULT=hang-before-hello key; }
check 'the name: unchanged when the build carries a fault' [ "$(fault)" != "$base" ]

keeps 'a target outside the agent changes' write "$sources/C/c.swift" C --restore write "$sources/C/c.swift" c
keeps 'a file outside KernovaKit changes' write "$repo/Kernova/App.swift" edited --restore write "$repo/Kernova/App.swift" app

# The manifest makes C a dependency of the agent: C's sources enter the name.
describe '"other", "kernova-agent"'
write "$repo/KernovaKit/Package.swift" 'C in the agent'
with_c=$(key)
write "$sources/C/c.swift" C
if [ "$(key)" = "$with_c" ]; then fail "unchanged when a target the agent newly depends on changes"; else pass; fi
write "$sources/C/c.swift" c
write "$repo/KernovaKit/Package.swift" manifest
describe '"other"'

elsewhere="$tmp/elsewhere/checkout"
new_repo "$elsewhere" || exit 1
other=$("$elsewhere/Tools/install-linux-guest-agent.sh" --path 2>"$tmp/err")
check "the same inputs in another checkout name another entry: '$other'" [ "$other" = "$base" ]

if [ "$FAIL" -gt 0 ]; then
    printf 'install-linux-guest-agent: %d failed, %d passed\n' "$FAIL" "$PASS" >&2
    exit 1
fi
printf '  %s✓%s install-linux-guest-agent: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
