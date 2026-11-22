#!/usr/bin/env bash
# Fixture tests for Tools/build-arenas.sh: what `clean` removes and when it
# refuses, what `sweep` unregisters and evicts, what `unregister` unregisters,
# and that `make index`, stopped by a TERM to make alone, ends only once its
# build has, with the bundles that build made unregistered. Runs a copy of the
# scripts and the Makefile inside a fixture clone, with HOME in the fixture and
# fakes for lsregister and xcodebuild first on PATH, so nothing reaches this
# machine's Launch Services database or builds. Every wait is on a fifo or a
# process. Local git only.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else fail "$1: got '$2', wanted '$3'"; fi
}

# A space in every path the scripts handle: HOME and the clone.
base="$(cd "$(mktemp -d)" && pwd -P)"
tmp="$base/with space"
mkdir -p "$tmp"
children=()
cleanup() {
    if [ "${#children[@]}" -gt 0 ]; then
        kill "${children[@]}" 2>/dev/null
        wait "${children[@]}" 2>/dev/null
    fi
    chmod -R u+w "$base" 2>/dev/null
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
chmod +x "$fakes"/*
export PATH="$fakes:$PATH"

# ---- the clone -----------------------------------------------------------------

clone="$tmp/clone"
git init -q -b main "$clone"
git -C "$clone" commit -q --allow-empty -m init
mkdir -p "$clone/Tools/lib"
cp "$ROOT/Tools/build-arenas.sh" "$ROOT/Tools/checkout-lock.sh" "$clone/Tools/"
cp "$ROOT/Tools/lib/build-arenas.sh" "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/worktrees.sh" \
    "$ROOT/Tools/lib/holders.sh" "$ROOT/Tools/lib/xcodebuild-flags.sh" "$ROOT/Tools/lib/swift-roots.sh" \
    "$clone/Tools/lib/"
cp "$ROOT/Makefile" "$clone/"
wts="$clone/.claude/worktrees"

# Every arena holds two bundles, one with a space in its name.
add_bundles() {
    mkdir -p "$1/Build/Products/Debug/Kernova.app" "$1/Build/Products/Debug/Kernova Guest Agent.app"
}
bundles_of() {
    printf '%s\n' "$1/Build/Products/Debug/Kernova Guest Agent.app" "$1/Build/Products/Debug/Kernova.app"
}
present() { if [ -e "$1" ]; then printf present; else printf gone; fi; }

# ---- sweep ---------------------------------------------------------------------

git -C "$clone" worktree add -q --detach "$wts/live"
git -C "$clone" worktree add -q --detach "$wts/gone"
git -C "$clone" worktree remove --force "$wts/gone"
caches="$HOME/Library/Caches/xcode-build-server"
live_cache="$caches/${wts//\//-}-live"
gone_cache="$caches/${wts//\//-}-gone"
held_cache="$caches/${wts//\//-}-held"
mkdir -p "$live_cache" "$gone_cache" "$held_cache"

(cd "$held_cache" && exec sleep 300) &
sweep_holder=$!
children+=("$sweep_holder")

cat >"$dump" <<EOF
--------------------------------------------------------------------------------
path:                       $wts/gone/DerivedData/Make/Build/Products/Debug/Kernova.app (0x1a2b)
identifier:                 app.kernova
--------------------------------------------------------------------------------
path:                       $wts/gone/DerivedData/Make/Build/Products/Debug/Kernova Guest Agent.app (0x1a2c)
identifier:                 app.kernova.guest-agent
--------------------------------------------------------------------------------
path:                       $wts/live (0x1a2d)
identifier:                 app.kernova
--------------------------------------------------------------------------------
path:                       $tmp/deleted/Unrelated.app (0x1a2e)
identifier:                 com.example.unrelated
EOF
: >"$unregistered"
"$clone/Tools/build-arenas.sh" sweep >/dev/null 2>&1
check "sweep: exit status" "$?" 0
check "sweep: Launch Services records whose bundle is gone" "$(sort "$unregistered")" "$(bundles_of "$wts/gone/DerivedData/Make")"
check "sweep: a live worktree's editor cache" "$(present "$live_cache")" present
check "sweep: a removed worktree's editor cache" "$(present "$gone_cache")" gone
check "sweep: a removed worktree's editor cache a process holds" "$(present "$held_cache")" present
kill "$sweep_holder" 2>/dev/null
wait "$sweep_holder" 2>/dev/null

# ---- clean ---------------------------------------------------------------------

dd="$clone/DerivedData"
reset_clean() {
    chmod -R u+w "$dd" 2>/dev/null
    rm -rf "$dd"
    add_bundles "$dd/Make"
    add_bundles "$dd/Periphery"
    : >"$unregistered"
}
run_clean() {
    clean_out=$("$clone/Tools/build-arenas.sh" clean 2>&1)
    clean_status=$?
}

reset_clean
run_clean
check "clean: exit status" "$clean_status" 0
check "clean: DerivedData/" "$(present "$dd")" gone
check "clean: unregisters what it removes" "$(sort "$unregistered")" "$(
    { bundles_of "$dd/Make"; bundles_of "$dd/Periphery"; } | sort
)"
check "clean: a live worktree" "$(present "$wts/live")" present

reset_clean
(cd "$dd/Make" && exec sleep 300) &
holder=$!
children+=("$holder")
run_clean
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
check "clean, held: exit status" "$((clean_status != 0))" 1
check "clean, held: names the holder" "$(grep -c "PID $holder" <<<"$clean_out")" 1
check "clean, held: removes nothing" "$(present "$dd/Make")$(present "$dd/Periphery")" presentpresent

reset_clean
mkdir -p "$dd/Locked"
touch "$dd/Locked/file"
chmod 555 "$dd/Locked"
run_clean
chmod 755 "$dd/Locked"
check "clean, a removal leaves something: exit status" "$((clean_status != 0))" 1
check "clean, a removal leaves something: names it" "$(grep -c 'failed to remove .*DerivedData' <<<"$clean_out")" 1

rm -rf "$dd"
run_clean
check "clean, nothing there: exit status" "$clean_status" 0
check "clean, nothing there: says so" "$(grep -c '^No build arena of this checkout to remove' <<<"$clean_out")" 1

# ---- make index, stopped -------------------------------------------------------

# xcodebuild stands in for a build that a TERM ends after it writes its app:
# it names itself on $FIXTURE/started, then waits; TERM makes the bundle and
# exits.
cat >"$fakes/xcodebuild" <<'EOF'
#!/bin/bash
products=DerivedData/Index/Build/Products/Debug
sleep 300 &
sleeper=$!
trap 'kill "$sleeper"; mkdir -p "$products/Kernova.app"; exit 143' TERM
echo "$$" >"$FIXTURE/started"
wait "$sleeper"
EOF
chmod +x "$fakes/xcodebuild"
mkfifo "$tmp/started"
: >"$unregistered"
FIXTURE=$tmp make -C "$clone" --no-print-directory index >/dev/null 2>&1 &
make_pid=$!
children+=("$make_pid")
read -r build_pid <"$tmp/started"
children+=("$build_pid")
kill -TERM "$make_pid"
wait "$make_pid" 2>/dev/null
check "make index, TERM to make alone: exit status" "$?" 143
check "make index, TERM to make alone: its build when make has ended" \
    "$(kill -0 "$build_pid" 2>/dev/null && echo running || echo gone)" gone
check "make index, TERM to make alone: the bundle its build made, unregistered" \
    "$(cat "$unregistered")" "$clone/DerivedData/Index/Build/Products/Debug/Kernova.app"

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
