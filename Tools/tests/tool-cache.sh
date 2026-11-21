#!/usr/bin/env bash
# Fixture tests for Tools/lib/tool-cache.sh, sourced from a copy in a scratch
# repository and run against stub `swift` and `xcrun`: what an entry's name
# hashes, and that an install leaves an entry whole and verified or nothing —
# when its build or verification fails, when its inputs change under it, when
# it is interrupted, and when two installs race — and what it prunes.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
# check <failure> <command>... — passes when the command succeeds.
check() {
    local failure=$1
    shift
    if "$@"; then pass; else fail "$failure"; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"
children=()
cleanup() {
    if [ "${#children[@]}" -gt 0 ]; then
        kill "${children[@]}" 2>/dev/null
        wait "${children[@]}" 2>/dev/null
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT
export HOME="$tmp/home" XDG_CACHE_HOME="$tmp/home/.cache"
mkdir -p "$HOME"

# The toolchain the stubs report, which a test changes by rewriting the files.
# Like a swiftly proxy, the stub `swift` serves the toolchain a `.swift-version`
# in the working directory or above it pins, and another one elsewhere.
toolchain() { # <compiler> <triple> <install location>
    printf '  "compilerVersion": "%s",\n  "unversionedTriple": "%s",\n  "runtimeResourcePath": "%s"\n' "$@" \
        >"$tmp/toolchain"
}
toolchain 'Swift 1' arm64-apple-macosx /toolchains/one
printf '  "compilerVersion": "Swift 0",\n' >"$tmp/unpinned"
echo 1A1 >"$tmp/sdk"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/swift" <<EOF
#!/bin/sh
[ "\$1" = -print-target-info ] || exit 1
dir=\$PWD
while [ "\$dir" != / ] && [ ! -f "\$dir/.swift-version" ]; do dir=\$(dirname "\$dir"); done
if [ -f "\$dir/.swift-version" ]; then exec cat "$tmp/toolchain"; else exec cat "$tmp/unpinned"; fi
EOF
printf '#!/bin/sh\nexec cat "%s"\n' "$tmp/sdk" >"$tmp/bin/xcrun"
chmod +x "$tmp/bin/swift" "$tmp/bin/xcrun"
export PATH="$tmp/bin:$PATH"

# A repository holding the library, a `.swift-version`, and the inputs the
# tests hash.
new_repo() { # <dir>
    mkdir -p "$1/Tools/lib" "$1/src/dir/sub" &&
        cp "$ROOT/Tools/lib/tool-cache.sh" "$1/Tools/lib/" && echo 1 >"$1/.swift-version" &&
        echo a >"$1/src/file" && echo b >"$1/src/dir/b" && echo c >"$1/src/dir/sub/c"
}
repo="$tmp/repo"
new_repo "$repo" || exit 1
copy="$tmp/elsewhere/repo"
new_repo "$copy" || exit 1
# shellcheck source=../lib/tool-cache.sh
. "$repo/Tools/lib/tool-cache.sh"
cache=$(tool_cache_root)

# ---- the entry's name ------------------------------------------------------------

key() { tool_dir t v -- src/file src/dir; }
base=$(key) || { fail "tool_dir failed on inputs that exist"; base=''; }
case "$base" in
    "$cache"/t-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) pass ;;
    *) fail "name: '$base' is not <cache>/t-<16 hex digits>" ;;
esac
check "name: two lookups of the same inputs differ" [ "$(key)" = "$base" ]
check "name: the same inputs in another checkout name another entry" \
    [ "$(bash -c '. "$1/Tools/lib/tool-cache.sh" && tool_dir t v -- src/file src/dir' _ "$copy")" = "$base" ]

# changes <what> <command>... — runs the command, which changes one input, and
# expects a different name; the command after `--restore` puts it back, and
# the name must return.
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
        fail "name: unchanged when $what"
    elif [ "$(key)" != "$base" ]; then
        fail "name: not restored when $what was undone"
    else
        pass
    fi
}
write() { printf '%s\n' "$2" >"$1"; }
changes 'a file changes' write "$repo/src/file" A --restore write "$repo/src/file" a
changes 'a nested file changes' write "$repo/src/dir/sub/c" C --restore write "$repo/src/dir/sub/c" c
changes 'a file is added under a directory' write "$repo/src/dir/new" n --restore rm "$repo/src/dir/new"
changes 'a file is renamed' mv "$repo/src/dir/b" "$repo/src/dir/b2" --restore mv "$repo/src/dir/b2" "$repo/src/dir/b"
# A symbolic link under a directory, to a file outside every path named, is
# read for its target's content.
echo l >"$tmp/linked"
ln -s "$tmp/linked" "$repo/src/dir/link"
base=$(key)
changes "a linked file's content changes" write "$tmp/linked" L --restore write "$tmp/linked" l
rm "$repo/src/dir/link"
base=$(key)
original=(toolchain 'Swift 1' arm64-apple-macosx /toolchains/one)
changes "the toolchain's compiler changes" toolchain 'Swift 2' arm64-apple-macosx /toolchains/one --restore "${original[@]}"
changes "the toolchain's target changes" toolchain 'Swift 1' aarch64-unknown-linux-gnu /toolchains/one \
    --restore "${original[@]}"
changes "the toolchain's install location changes" toolchain 'Swift 1' arm64-apple-macosx /toolchains/two \
    --restore "${original[@]}"
if [ "$(uname -s)" = Darwin ]; then
    changes 'the SDK changes' write "$tmp/sdk" 1A2 --restore write "$tmp/sdk" 1A1
fi
check "name: unchanged when a value changes" [ "$(tool_dir t w -- src/file src/dir)" != "$base" ]
check "name: unchanged when a value is added" [ "$(tool_dir t v x -- src/file src/dir)" != "$base" ]
check "name: unchanged when a path is dropped" [ "$(tool_dir t v -- src/file)" != "$base" ]
fails() { ! "$@" 2>/dev/null; }
check "name: a path that does not exist named an entry" fails tool_dir t v -- src/missing
# homeless <unset | empty> — tool_dir with no home directory fails and prints no path.
homeless() {
    local out
    if out=$(unset XDG_CACHE_HOME; if [ "$1" = unset ]; then unset HOME; else HOME=''; fi
        tool_dir t v -- src/file 2>/dev/null); then
        return 1
    fi
    [ -z "$out" ]
}
check "name: with HOME unset, tool_dir did not fail, or printed a path" homeless unset
check "name: with HOME empty, tool_dir did not fail, or printed a path" homeless empty

# ---- installs ----------------------------------------------------------------------

# Builds write a tool that prints which build made it; verify runs it.
builds="$tmp/builds"
: >"$builds"
build_ok() { echo build >>"$builds" && printf '#!/bin/sh\necho %s\n' "${BUILD_ID:-built}" >"$1/tool" && chmod +x "$1/tool"; }
build_broken() { printf '#!/bin/sh\nexit 1\n' >"$1/tool" && chmod +x "$1/tool"; }
build_fails() { echo partial >"$1/tool" && return 1; }
build_edits() { build_ok "$1" && echo edited >"$repo/src/file"; }
verify_ok() { "$1/tool" >/dev/null; }

# Every entry and staging directory in the cache, one per line.
listing() { ls -A "$cache" 2>/dev/null; }

# nothing_left <case> <status> — the install failed and left the cache as it was.
nothing_left() {
    if [ "$2" -eq 0 ]; then
        fail "$1: the install succeeded"
    elif [ "$(listing)" != "$before" ]; then
        fail "$1: left '$(listing | tr '\n' ' ')' where '$(printf '%s' "$before" | tr '\n' ' ')' was"
    else
        pass
    fi
}

entry=$(tool_dir t v -- src/file)
out=$(tool_install build_ok verify_ok t v -- src/file)
status=$?
if [ "$status" -ne 0 ] || [ "$out" != "$entry" ]; then
    fail "install: exited $status printing '$out', wanted $entry"
elif [ "$("$entry/tool")" != built ] || [ "$(listing)" != "${entry##*/}" ]; then
    fail "install: the cache holds '$(listing | tr '\n' ' ')', wanted ${entry##*/} alone with the built tool"
else
    pass
fi
out=$(tool_install build_fails verify_ok t v -- src/file)
check "install: an installed entry was not printed ('$out')" [ "$out" = "$entry" ]
check "install: an installed entry was built again" [ "$(wc -l <"$builds" | tr -d ' ')" -eq 1 ]

# Called from a directory whose `swift` is another toolchain, the build still
# uses the toolchain the entry's name was read with.
build_records() { swift -print-target-info >"$1/toolchain" && build_ok "$1"; }
mkdir -p "$tmp/outside"
seen=$(cd "$tmp/outside" && tool_install build_records verify_ok t cwd -- src/file)
check "install: called from outside the repository, the build used '$(cat "$seen/toolchain" 2>/dev/null)', not the toolchain its name was read with" \
    cmp -s "$seen/toolchain" "$tmp/toolchain"

before=$(listing)
tool_install build_broken verify_ok t verify-fails -- src/file >/dev/null 2>&1
nothing_left 'a build that does not run' $?
tool_install build_fails verify_ok t build-fails -- src/file >/dev/null 2>&1
nothing_left 'a build that fails' $?
tool_install build_edits verify_ok t edited -- src/file >/dev/null 2>&1
status=$?
write "$repo/src/file" a
nothing_left 'inputs that change during the build' "$status"

# A build whose child process says it started and then blocks until its gate
# is written, so a signal sent once it has started reaches that child: the
# install runs in its own process group, as a terminal's interrupt or a
# cancelled job signals every process of the job.
build_gated() {
    perl -e 'open(my $s, ">", $ARGV[0]) or die; print $s "started\n"; close $s; open(my $g, "<", $ARGV[1]) or die; <$g>' \
        "$tmp/started-$BUILD_ID" "$tmp/gate-$BUILD_ID" && build_ok "$1"
}
start_gated() { # <id> <value> — leaves the install's pid, its process group's id, in $pid
    mkfifo "$tmp/started-$1" "$tmp/gate-$1"
    set -m
    # The job outlives a signal to the group until the install has exited, so
    # waiting for it waits for the install's own cleanup.
    (
        set +m
        trap : INT TERM HUP
        BUILD_ID=$1 tool_install build_gated verify_ok t "$2" -- src/file >"$tmp/out-$1" 2>/dev/null
    ) &
    pid=$!
    set +m
    children+=("$pid")
    read -r _ <"$tmp/started-$1"
}

for signal in INT TERM HUP; do
    before=$(listing)
    start_gated "$signal" "interrupted-$signal"
    kill -s "$signal" -- "-$pid"
    wait "$pid"
    nothing_left "an install interrupted by SIG$signal" $?
done

# Two installs of one entry, both past their builds before either renames:
# the first rename lands, and the second install keeps that entry.
race=$(tool_dir t race -- src/file)
start_gated first race
first=$pid
start_gated second race
second=$pid
echo go >"$tmp/gate-first"
wait "$first"
first_status=$?
echo go >"$tmp/gate-second"
wait "$second"
second_status=$?
if [ "$first_status" -ne 0 ] || [ "$second_status" -ne 0 ]; then
    fail "race: the installs exited $first_status and $second_status"
elif [ "$(cat "$tmp/out-first")" != "$race" ] || [ "$(cat "$tmp/out-second")" != "$race" ]; then
    fail "race: the installs printed '$(cat "$tmp/out-first")' and '$(cat "$tmp/out-second")', wanted $race"
elif [ "$("$race/tool")" != first ]; then
    fail "race: the entry holds '$("$race/tool")', wanted the first install's tool"
elif [ -n "$(find "$cache" -mindepth 1 -maxdepth 1 -name '.*')" ] || [ -n "$(find "$race" -mindepth 1 ! -name tool)" ]; then
    fail "race: the cache holds '$(listing | tr '\n' ' ')' and the entry '$(find "$race" -mindepth 1 | tr '\n' ' ')'"
else
    pass
fi

# ---- pruning -------------------------------------------------------------------------

# An entry looked up stays however old it is; one unused for 30 days, and a
# staging directory a killed install left, go when an install builds.
old=200001010000
used=$(tool_dir t used -- src/file)
tool_install build_ok verify_ok t used -- src/file >/dev/null
mkdir "$cache/t-0000000000000000" "$cache/.t-0000000000000000.abcdef"
touch -t "$old" "$used" "$cache/t-0000000000000000" "$cache/.t-0000000000000000.abcdef"
tool_install build_ok verify_ok t used -- src/file >/dev/null
fresh=$(tool_install build_ok verify_ok t fresh -- src/file)
if [ -e "$cache/t-0000000000000000" ] || [ -e "$cache/.t-0000000000000000.abcdef" ]; then
    fail "prune: kept what no install used for 30 days: $(listing | tr '\n' ' ')"
elif [ ! -x "$used/tool" ] || [ ! -x "$fresh/tool" ]; then
    fail "prune: removed an entry in use: $(listing | tr '\n' ' ')"
else
    pass
fi

# Of one name's entries, an install that builds keeps the ten used last, its
# own among them; another name's entries stay, one whose name begins with this
# one's included.
aged() { perl -e 'my $t = time - $ARGV[0] * 60; utime($t, $t, $ARGV[1]) or die "$ARGV[1]: $!\n"' "$1" "$2"; }
for minutes in 1 2 3 4 5 6 7 8 9 10 11; do
    mkdir "$cache/n-$(printf '%016x' "$minutes")" && aged "$minutes" "$cache/n-$(printf '%016x' "$minutes")"
done
mkdir "$cache/n-m-0000000000000001" && aged 100 "$cache/n-m-0000000000000001"
newest=$(tool_install build_ok verify_ok n new -- src/file)
kept=$(cd "$cache" && printf '%s\n' n-* | LC_ALL=C sort | tr '\n' ' ')
wanted=$( (printf '%s\n' "${newest##*/}" n-m-0000000000000001; for minutes in 1 2 3 4 5 6 7 8 9; do
    printf 'n-%016x\n' "$minutes"; done) | LC_ALL=C sort | tr '\n' ' ')
if [ "$kept" = "$wanted" ]; then pass; else
    fail "prune: kept '$kept' of one name's entries, wanted '$wanted'"
fi

if [ "$FAIL" -gt 0 ]; then
    printf 'tool-cache: %d failed, %d passed\n' "$FAIL" "$PASS" >&2
    exit 1
fi
printf '  %s✓%s tool-cache: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
