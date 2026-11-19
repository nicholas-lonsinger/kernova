#!/usr/bin/env bash
# Fixture tests for Tools/build-arenas.sh: which arenas `clean` and `sweep`
# remove, which they leave, and what `unregister` unregisters. Runs a copy of
# the scripts inside a fixture clone, with HOME in the fixture and fakes for
# xcodebuild, lsregister and defaults first on PATH, so nothing reaches this
# machine's DerivedData or Launch Services database. Local git only.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else fail "$1: got '$2', wanted '$3'"; fi
}

# A space in every path the scripts handle: HOME, so the arena root, and the
# clone.
base="$(cd "$(mktemp -d)" && pwd -P)"
tmp="$base/with space"
mkdir -p "$tmp"
children=()
cleanup() {
    if [ "${#children[@]}" -gt 0 ]; then
        kill "${children[@]}" 2>/dev/null
        wait "${children[@]}" 2>/dev/null
    fi
    rm -rf "$base"
}
trap cleanup EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

# ---- fakes ---------------------------------------------------------------------

fakes="$tmp/fakes"
mkdir -p "$fakes"
dump="$tmp/lsregister-dump"
unregistered="$tmp/lsregister-unregistered"
: >"$dump"
cat >"$fakes/lsregister" <<EOF
#!/bin/bash
case "\$1" in
    -dump) cat '$dump' ;;
    -u) printf '%s\n' "\$2" >>'$unregistered' ;;
esac
EOF
# No custom derived-data location, so the arena root is under HOME.
printf '#!/bin/bash\nexit 1\n' >"$fakes/defaults"
# -showBuildSettings answers BUILD_DIR = $FAKE_BUILD_DIR and, as xcodebuild
# does, creates the arena it names; FAKE_XCODEBUILD=fail fails, =nocreate
# creates nothing.
cat >"$fakes/xcodebuild" <<'EOF'
#!/bin/bash
[ "${FAKE_XCODEBUILD:-}" = fail ] && { echo 'xcodebuild: error: fake failure' >&2; exit 65; }
case "$FAKE_BUILD_DIR" in
    */Build/Products) [ "${FAKE_XCODEBUILD:-}" = nocreate ] || mkdir -p "${FAKE_BUILD_DIR%/Build/Products}/Logs" ;;
esac
printf 'Build settings for action build and target Kernova:\n    BUILD_DIR = %s\n' "$FAKE_BUILD_DIR"
EOF
chmod +x "$fakes"/*
export PATH="$fakes:$PATH"

# ---- the clone -----------------------------------------------------------------

clone="$tmp/clone"
git init -q -b main "$clone"
mkdir -p "$clone/Kernova.xcodeproj"
touch "$clone/Kernova.xcodeproj/project.pbxproj"
git -C "$clone" add Kernova.xcodeproj && git -C "$clone" commit -q -m init
mkdir -p "$clone/Tools/lib"
cp "$ROOT/Tools/build-arenas.sh" "$ROOT/Tools/arena-label.sh" "$ROOT/Tools/derived-data-path.sh" \
    "$ROOT/Tools/checkout-lock.sh" "$clone/Tools/"
cp "$ROOT/Tools/lib/build-arenas.sh" "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/worktrees.sh" \
    "$ROOT/Tools/lib/holders.sh" "$ROOT/Tools/lib/xcodebuild-flags.sh" "$clone/Tools/lib/"
wts="$clone/.claude/worktrees"
add_worktree() { git -C "$clone" worktree add -q --detach "$1"; }

dd_root="$HOME/Library/Developer/Xcode/DerivedData"
check "arena root" "$("$clone/Tools/derived-data-path.sh" --root)" "$dd_root"

# ---- arenas --------------------------------------------------------------------

# Every arena holds two bundles, one with a space in its name.
add_bundles() {
    mkdir -p "$1/Build/Products/Debug/Kernova.app" "$1/Build/Products/Debug/Kernova Guest Agent.app"
}
bundles_of() {
    printf '%s\n' "$1/Build/Products/Debug/Kernova Guest Agent.app" "$1/Build/Products/Debug/Kernova.app"
}
# recorded_arena <project> — the arena Xcode names for <project>, recording it
# in info.plist as a build does; prints its path.
recorded_arena() {
    local arena
    arena=$("$clone/Tools/derived-data-path.sh" "$1")
    add_bundles "$arena"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>WorkspacePath</key><string>%s</string></dict></plist>\n' \
        "$1" >"$arena/info.plist"
    printf '%s' "$arena"
}
# pif_arena <project> — recording <project> only in the PIF cache, as an arena
# that never built does.
pif_arena() {
    local arena record
    arena=$("$clone/Tools/derived-data-path.sh" "$1")
    record="$arena/Build/Intermediates.noindex/XCBuildData/PIFCache/workspace"
    mkdir -p "$record"
    printf '{"path": "%s/project.xcworkspace"}\n' "$1" >"$record/WORKSPACE@v11_hash=0-json"
    printf '%s' "$arena"
}
# bare_arena <project> <entry>... — named for <project>, recording nothing.
bare_arena() {
    local arena entry
    arena=$("$clone/Tools/derived-data-path.sh" "$1")
    shift
    for entry in "$@"; do mkdir -p "$arena/$entry"; done
    printf '%s' "$arena"
}
present() { if [ -e "$1" ]; then printf present; else printf gone; fi; }

# ---- sweep ---------------------------------------------------------------------

add_worktree "$wts/live"
for name in gone 'gone space' stray pif held moving hand; do add_worktree "$wts/$name"; done

main_arena=$(recorded_arena "$clone/Kernova.xcodeproj")
live_arena=$(recorded_arena "$wts/live/Kernova.xcodeproj")
gone_arena=$(recorded_arena "$wts/gone/Kernova.xcodeproj")
gone_space_arena=$(recorded_arena "$wts/gone space/Kernova.xcodeproj")
stray_arena=$(recorded_arena "$wts/stray/Kernova.xcodeproj")
pif_gone_arena=$(pif_arena "$wts/pif/Kernova.xcodeproj")
held_arena=$(recorded_arena "$wts/held/Kernova.xcodeproj")
moved_from_arena=$(recorded_arena "$wts/moving/Kernova.xcodeproj")
hand_from_arena=$(recorded_arena "$wts/hand/Kernova.xcodeproj")
for name in gone 'gone space' stray pif held; do git -C "$clone" worktree remove --force "$wts/$name"; done
# A write after removal recreates the directory, unregistered and projectless.
mkdir -p "$wts/stray/DerivedData"
git -C "$clone" worktree move "$wts/moving" "$wts/moved"
moved_to_arena=$(recorded_arena "$wts/moved/Kernova.xcodeproj")
# Moved by hand: git still lists the old path, and the checkout builds at the
# new one.
mv "$wts/hand" "$wts/hand moved"
hand_to_arena=$(recorded_arena "$wts/hand moved/Kernova.xcodeproj")

# Outside this clone's worktrees, none of which the sweep can know is gone.
mkdir -p "$tmp/other clone/Kernova.xcodeproj"
other_arena=$(recorded_arena "$tmp/other clone/Kernova.xcodeproj")
other_gone_arena=$(recorded_arena "$tmp/unmounted/Kernova.xcodeproj")
git -C "$clone" worktree add -q --detach "$tmp/outside wt"
outside_arena=$(bare_arena "$tmp/outside wt/Kernova.xcodeproj" Logs SourcePackages)
unclaimed_arena=$(bare_arena "$tmp/nowhere/Kernova.xcodeproj" Logs SourcePackages)
unattributable_arena=$(bare_arena "$tmp/nowhere-built/Kernova.xcodeproj" Logs Build)
other_project_arena="$dd_root/Other-$(printf 'a%.0s' {1..28})"
mkdir -p "$other_project_arena"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>WorkspacePath</key><string>%s</string></dict></plist>\n' \
    "$wts/gone/Other.xcodeproj" >"$other_project_arena/info.plist"

(cd "$held_arena" && exec sleep 300) &
sweep_holder=$!
children+=("$sweep_holder")

cat >"$dump" <<EOF
--------------------------------------------------------------------------------
path:                       $tmp/deleted/Kernova.app (0x1a2b)
identifier:                 app.kernova
--------------------------------------------------------------------------------
path:                       $tmp/deleted/Kernova Guest Agent.app (0x1a2c)
identifier:                 app.kernova.guest-agent
--------------------------------------------------------------------------------
path:                       $live_arena/Build/Products/Debug/Kernova.app (0x1a2d)
identifier:                 app.kernova
--------------------------------------------------------------------------------
path:                       $tmp/deleted/Unrelated.app (0x1a2e)
identifier:                 com.example.unrelated
EOF
: >"$unregistered"
sweep_out=$("$clone/Tools/build-arenas.sh" sweep 2>&1)

check "sweep: main checkout's arena" "$(present "$main_arena")" present
check "sweep: live worktree's arena" "$(present "$live_arena")" present
check "sweep: removed worktree's arena" "$(present "$gone_arena")" gone
check "sweep: removed worktree with a space in its name" "$(present "$gone_space_arena")" gone
check "sweep: removed worktree whose directory was recreated" "$(present "$stray_arena")" gone
check "sweep: removed worktree recorded only in the PIF cache" "$(present "$pif_gone_arena")" gone
check "sweep: removed worktree's arena a process holds" "$(present "$held_arena")" present
check "sweep: git-moved worktree's arena at its old path" "$(present "$moved_from_arena")" gone
check "sweep: git-moved worktree's arena at its new path" "$(present "$moved_to_arena")" present
check "sweep: hand-moved worktree's arena at its listed path" "$(present "$hand_from_arena")" gone
check "sweep: hand-moved worktree's arena where it builds" "$(present "$hand_to_arena")" present
check "sweep: another clone's arena" "$(present "$other_arena")" present
check "sweep: arena of a checkout outside the clone that reads as removed" "$(present "$other_gone_arena")" present
check "sweep: registered worktree outside .claude/worktrees, packages only" "$(present "$outside_arena")" present
check "sweep: arena recording no checkout, packages only" "$(present "$unclaimed_arena")" present
check "sweep: arena recording no checkout, with build output" "$(present "$unattributable_arena")" present
check "sweep: another project's arena" "$(present "$other_project_arena")" present
check "sweep: Launch Services records unregistered" "$(sort "$unregistered")" "$(
    {
        printf '%s\n' "$tmp/deleted/Kernova.app" "$tmp/deleted/Kernova Guest Agent.app"
        for arena in "$gone_arena" "$gone_space_arena" "$stray_arena" "$moved_from_arena" "$hand_from_arena"; do
            bundles_of "$arena"
        done
    } | sort
)"
check "sweep: names what it evicted" "$(grep -c 'evicted orphaned DerivedData arena' <<<"$sweep_out")" 6
kill "$sweep_holder" 2>/dev/null
wait "$sweep_holder" 2>/dev/null

# ---- clean ---------------------------------------------------------------------

# Where xcodebuild says this checkout builds — deliberately not the arena
# Tools/derived-data-path.sh computes, so only xcodebuild's answer can find it.
xcode_arena="$dd_root/Kernova-$(printf 'x%.0s' {1..28})"
reset_clean() {
    rm -rf "$xcode_arena" "$clone/DerivedData"
    add_bundles "$xcode_arena"
    add_bundles "$clone/DerivedData/Periphery"
    : >"$unregistered"
}
run_clean() { clean_out=$(FAKE_BUILD_DIR=$1 FAKE_XCODEBUILD=${2:-} "$clone/Tools/build-arenas.sh" clean 2>&1); clean_status=$?; }

reset_clean
run_clean "$xcode_arena/Build/Products"
check "clean: exit status" "$clean_status" 0
check "clean: xcodebuild's arena" "$(present "$xcode_arena")" gone
check "clean: in-checkout DerivedData/" "$(present "$clone/DerivedData")" gone
check "clean: names the arena it removed" "$(grep -c "Removing build arena .*Kernova-xxxx" <<<"$clean_out")" 1
check "clean: unregisters what it removes" "$(sort "$unregistered")" "$(
    { bundles_of "$xcode_arena"; bundles_of "$clone/DerivedData/Periphery"; } | sort
)"
check "clean: the main checkout's other arena" "$(present "$main_arena")" present
check "clean: a live worktree's arena" "$(present "$live_arena")" present
check "clean: another project's arena" "$(present "$other_project_arena")" present

reset_clean
run_clean "$xcode_arena/Build/Products" fail
check "clean, xcodebuild fails: exit status" "$((clean_status != 0))" 1
check "clean, xcodebuild fails: says what it asked" "$(grep -c 'showBuildSettings` failed' <<<"$clean_out")" 1
check "clean, xcodebuild fails: DerivedData/" "$(present "$clone/DerivedData")" present

reset_clean
run_clean "$xcode_arena/Build"
check "clean, BUILD_DIR not in an arena: exit status" "$((clean_status != 0))" 1
check "clean, BUILD_DIR not in an arena: names it" "$(grep -c "BUILD_DIR is '$xcode_arena/Build'" <<<"$clean_out")" 1
check "clean, BUILD_DIR not in an arena: DerivedData/" "$(present "$clone/DerivedData")" present

reset_clean
(cd "$xcode_arena" && exec sleep 300) &
holder=$!
children+=("$holder")
run_clean "$xcode_arena/Build/Products"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
check "clean, arena held: exit status" "$((clean_status != 0))" 1
check "clean, arena held: names the holder" "$(grep -c "PID $holder" <<<"$clean_out")" 1
check "clean, arena held: arena" "$(present "$xcode_arena")" present
check "clean, arena held: DerivedData/ too" "$(present "$clone/DerivedData")" present

reset_clean
run_clean "$clone/DerivedData/Kernova/Build/Products"
check "clean, arena inside DerivedData/: exit status" "$clean_status" 0
check "clean, arena inside DerivedData/: DerivedData/" "$(present "$clone/DerivedData")" gone

rm -rf "$xcode_arena" "$clone/DerivedData"
run_clean "$xcode_arena/Build/Products" nocreate
check "clean, nothing there: exit status" "$clean_status" 0
check "clean, nothing there: says so" "$(grep -c '^No build arena to remove' <<<"$clean_out")" 1

# ---- unregister ----------------------------------------------------------------

: >"$unregistered"
"$clone/Tools/build-arenas.sh" unregister "$tmp/no such arena"
check "unregister, missing directory: exit status" "$?" 0
mkdir -p "$tmp/empty arena"
"$clone/Tools/build-arenas.sh" unregister "$tmp/empty arena"
check "unregister, no bundles: exit status" "$?" 0
check "unregister, nothing registered: unregisters nothing" "$(cat "$unregistered")" ''

add_bundles "$tmp/periphery"
(cd "$tmp" && "$clone/Tools/build-arenas.sh" unregister periphery/Build/Products)
check "unregister, relative directory: absolute bundle paths" "$(sort "$unregistered")" "$(bundles_of "$tmp/periphery")"
check "unregister: leaves the bundles" "$(present "$tmp/periphery/Build/Products/Debug/Kernova.app")" present

"$clone/Tools/build-arenas.sh" unregister 2>/dev/null
check "unregister, no directory: exit status" "$?" 2

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s build-arenas: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
