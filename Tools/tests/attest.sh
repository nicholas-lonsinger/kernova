#!/usr/bin/env bash
# Fixture tests for Tools/attest.sh: `record <kind>` runs Tools/<kind>.sh, passes
# its output and status through and records only a passing run whose
# fingerprint held, never a lint run beside an untracked file; the clean-tree
# content tree is HEAD's; the Makefile's `lint` and `test` record a passing run
# of their script under plain make and nothing under `make -n` or over a
# failing script under `make -i`, `make test` passes its script nothing
# whatever variables the command line sets and refuses a configuration other
# than Debug; `attest` refuses a dirty or unpushed HEAD before any run, reuses
# a lint and a test record or runs `make lint` and `make test` for the ones
# missing and posts success only on both; and `post` takes only success or
# failure. Runs in a fixture clone with stub xcodebuild, sw_vers, gh, the two
# scripts, and make — the real make for the Makefile's own recipes.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else fail "$1: got '$2', wanted '$3'"; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

clone="$tmp/clone"
git init -q -b main "$clone"
mkdir -p "$clone/Tools/lib" "$clone/Config"
cp "$ROOT/Tools/attest.sh" "$ROOT/Tools/checkout-lock.sh" "$clone/Tools/"
cp "$ROOT/Tools/lib/swift-roots.sh" "$ROOT/Tools/lib/xcodebuild-flags.sh" "$clone/Tools/lib/"
cp "$ROOT/Makefile" "$clone/"
# Tools/lint.sh and Tools/test.sh log their run, arguments included, then run
# $FIXTURE/<kind>.run.
for script in lint test; do
    cat >"$clone/Tools/$script.sh" <<'EOF'
#!/bin/bash
kind=${0##*/}
kind=${kind%.sh}
echo "$kind${*:+ $*}" >>"$FIXTURE/ran.log"
. "$FIXTURE/$kind.run"
EOF
done
printf '#!/bin/bash\n' >"$clone/Tools/hooks-installed.sh"
chmod +x "$clone/Tools"/*.sh
printf 'Config/Local.xcconfig\n' >"$clone/.gitignore"
echo one >"$clone/file"
git -C "$clone" add -A && git -C "$clone" commit -q -m init
attest="$clone/Tools/attest.sh"
records="$clone/.git/kernova-attest"

real_make=$(command -v make)
stubs="$tmp/stubs"
mkdir -p "$stubs"
cat >"$stubs/xcodebuild" <<'EOF'
#!/bin/bash
[ "$*" = -version ] && printf 'Xcode 27.0\nBuild version 27A100\n'
EOF
cat >"$stubs/sw_vers" <<'EOF'
#!/bin/bash
[ "$*" = -buildVersion ] && echo 26Z42
EOF
# gh logs each call; GitHub has a commit while $FIXTURE/pushed exists.
cat >"$stubs/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FIXTURE/gh.log"
case "$*" in
    'api repos/{owner}/{repo}/commits/'*) [ -e "$FIXTURE/pushed" ] ;;
esac
EOF
# make <kind> as $FIXTURE/<kind>.mode says: a recorded pass, a failure, or a
# pass that records nothing.
cat >"$stubs/make" <<'EOF'
#!/bin/bash
echo "$*" >>"$FIXTURE/make.log"
case "$(cat "$FIXTURE/$1.mode")" in
    record) exec "$ATTEST" record "$1" ;;
    fail) exit 2 ;;
    norecord) exit 0 ;;
esac
EOF
chmod +x "$stubs"/*
export FIXTURE="$tmp" ATTEST="$attest" MAKE="$stubs/make" PATH="$stubs:$PATH"

reset() {
    rm -rf "$records" "$tmp/gh.log" "$tmp/make.log" "$tmp/ran.log"
    echo record >"$tmp/lint.mode"
    echo record >"$tmp/test.mode"
    echo 'exit 0' >"$tmp/lint.run"
    echo 'exit 0' >"$tmp/test.run"
}
# runs <kind> <bash> — what Tools/<kind>.sh does after logging its run.
runs() { printf '%s\n' "$2" >"$tmp/$1.run"; }
record_count() { find "$records" -type f 2>/dev/null | wc -l | tr -d ' '; }
record_line() { awk -v key="$1" '$1 == key { print $2 }' "$records"/*/* 2>/dev/null; }
calls() { cat "$tmp/$1.log" 2>/dev/null; }
in_clone() { (cd "$clone" && "$@"); }

# ---- record ---------------------------------------------------------------------

reset
runs test 'echo out; echo err >&2'
out=$(in_clone "$attest" record test 2>"$tmp/err")
check "record runs Tools/test.sh with no arguments" "$(calls ran)" test
check "record passes stdout through" "$out" out
check "record passes stderr through" "$(cat "$tmp/err")" err
check "a passing run is recorded" "$(record_count)" 1
check "the clean tree's content tree is HEAD's" "$(record_line tree)" "$(git -C "$clone" rev-parse 'HEAD^{tree}')"
check "the record's Xcode build" "$(record_line xcode)" 27A100
check "the record's macOS build" "$(record_line macos)" 26Z42
check "the record without Config/Local.xcconfig" "$(record_line local-xcconfig)" none
check "the record's date" "$(record_line date | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" 1

reset
runs test 'exit 3'
in_clone "$attest" record test
check "a failing run's status" "$?" 3
check "a failing run is not recorded" "$(record_count)" 0

reset
runs test 'echo changed >file'
in_clone "$attest" record test 2>"$tmp/err"
check "a run that changes files keeps its status" "$?" 0
check "a run that changes files is not recorded" "$(record_count)" 0
check "a run that changes files says so" "$(cat "$tmp/err")" 'attest: the files changed during the run, so it is not recorded'
git -C "$clone" checkout -q -- file

reset
echo dirty >"$clone/untracked"
index_before=$(shasum "$clone/.git/index")
in_clone "$attest" record test
check "a dirty tree is recorded" "$(record_count)" 1
check "a dirty tree's content tree" "$(record_line tree)" \
    "$(cd "$clone" && cp .git/index "$tmp/index" && GIT_INDEX_FILE="$tmp/index" git add -A && GIT_INDEX_FILE="$tmp/index" git write-tree)"
check "a dirty tree's content tree is not HEAD's" "$([ "$(record_line tree)" != "$(git -C "$clone" rev-parse 'HEAD^{tree}')" ] && echo differs || echo same)" differs
check "the real index is untouched" "$(shasum "$clone/.git/index")" "$index_before"
rm "$clone/untracked"

# Lint reads an untracked file (a link check sees it on disk) without listing
# it, so with one present a passing lint vouches for nothing it could name.
reset
mkdir -p "$clone/notes"
echo '[new](new.md)' >"$clone/notes/index.md"
git -C "$clone" add notes/index.md
echo new >"$clone/notes/new.md"
in_clone "$attest" record lint 2>"$tmp/err"
check "a lint run beside an untracked file runs Tools/lint.sh" "$(calls ran)" lint
check "a lint run beside an untracked file keeps its status" "$?" 0
check "a lint run beside an untracked file is not recorded" "$(record_count)" 0
check "a lint run beside an untracked file says so" "$(cat "$tmp/err")" 'attest: untracked files are present, so this lint run is not recorded: notes/new.md'
git -C "$clone" rm -q --cached notes/index.md
rm -r "$clone/notes"

reset
echo 'DEVELOPMENT_TEAM = X' >"$clone/Config/Local.xcconfig"
in_clone "$attest" record test
check "the record with Config/Local.xcconfig" "$(record_line local-xcconfig)" "$(git hash-object "$clone/Config/Local.xcconfig")"
rm "$clone/Config/Local.xcconfig"

reset
mkdir -p "$records"
touch -t 202001010000 "$records/stale"
in_clone "$attest" record lint
check "a write prunes records over 30 days old" "$([ -e "$records/stale" ] && echo kept || echo pruned)" pruned
check "a write keeps its own record" "$(record_count)" 1

reset
touch "$records"
in_clone "$attest" record test 2>"$tmp/err"
check "a run whose record cannot be written keeps its status" "$?" 0
check "a run whose record cannot be written says so" "$(grep -c 'cannot write the record' "$tmp/err")" 1
rm -f "$records"

# ---- make lint, make test --------------------------------------------------------

# make_in_clone <make argument>... — the clone's Makefile under the real make,
# with nothing inherited from a make that runs this suite.
make_in_clone() {
    (cd "$clone" && env -u MAKE -u MAKEFLAGS -u MFLAGS -u MAKELEVEL "$real_make" --no-print-directory "$@" >/dev/null 2>&1)
}

for kind in lint test; do
    reset
    make_in_clone "$kind"
    check "make $kind runs Tools/$kind.sh" "$(calls ran)" "$kind"
    check "make $kind records a passing run" "$(record_count)" 1

    reset
    make_in_clone -n "$kind"
    check "make -n $kind runs Tools/$kind.sh" "$(calls ran)" ''
    check "make -n $kind records" "$(record_count)" 0

    reset
    runs "$kind" 'exit 1'
    make_in_clone -i "$kind"
    check "make -i $kind runs Tools/$kind.sh" "$(calls ran)" "$kind"
    check "make -i $kind records a failing run" "$(record_count)" 0
done

reset
make_in_clone test 'XCODEBUILD_FLAGS=-only-testing:KernovaCoreTests' SCHEME=Other
check "make test with flag variables passes Tools/test.sh nothing" "$(calls ran)" test

reset
make_in_clone test CONFIGURATION=Release
check "make test in Release: status" "$?" 2
check "make test in Release runs Tools/test.sh" "$(calls ran)" ''
check "make test in Release records" "$(record_count)" 0

# ---- attest ---------------------------------------------------------------------

sha=$(git -C "$clone" rev-parse HEAD)
status_call() { printf 'api -X POST repos/{owner}/{repo}/statuses/%s -f state=%s -f context=Commit Attestation -f description=make attest: Xcode 27A100, macOS 26Z42' "$sha" "$1"; }

reset
touch "$tmp/pushed"
echo dirty >"$clone/untracked"
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "a dirty tree's attest status" "$?" 1
check "a dirty tree's refusal" "$err" 'attest: attest certifies HEAD; commit or stash first'
check "a dirty tree calls GitHub" "$(calls gh)" ''
check "a dirty tree runs make" "$(calls make)" ''
rm "$clone/untracked"

reset
rm -f "$tmp/pushed"
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "an unpushed HEAD's attest status" "$?" 1
check "an unpushed HEAD's refusal" "$err" "attest: GitHub does not have $sha; push first"
check "an unpushed HEAD runs make" "$(calls make)" ''
touch "$tmp/pushed"

reset
in_clone "$attest" record lint
in_clone "$attest" record test
out=$(in_clone "$attest")
check "a recorded HEAD's attest status" "$?" 0
check "a recorded HEAD says it reused the lint run" "$(printf '%s\n' "$out" | grep -c '^attest: reusing the passing make lint of ')" 1
check "a recorded HEAD says it reused the test run" "$(printf '%s\n' "$out" | grep -c '^attest: reusing the passing make test of ')" 1
check "a recorded HEAD runs make" "$(calls make)" ''
check "a recorded HEAD posts success" "$(calls gh | tail -1)" "$(status_call success)"

reset
in_clone "$attest" record test
in_clone "$attest" >/dev/null
check "a HEAD with only a test record: attest status" "$?" 0
check "a HEAD with only a test record runs make lint" "$(calls make)" lint
check "a HEAD with only a test record posts success" "$(calls gh | tail -1)" "$(status_call success)"

reset
in_clone "$attest" >/dev/null
check "an unrecorded HEAD's attest status" "$?" 0
check "an unrecorded HEAD runs make lint, then make test" "$(calls make | tr '\n' ' ')" 'lint test '
check "a passing run posts success" "$(calls gh | tail -1)" "$(status_call success)"

reset
in_clone "$attest" record test
echo fail >"$tmp/lint.mode"
in_clone "$attest" >/dev/null
check "a failing lint's attest status" "$?" 1
check "a failing lint posts failure" "$(calls gh | tail -1)" "$(status_call failure)"
check "a failing lint posts once" "$(calls gh | grep -c statuses)" 1

reset
echo fail >"$tmp/test.mode"
in_clone "$attest" >/dev/null
check "a failing test run's attest status" "$?" 1
check "a failing test run posts failure" "$(calls gh | tail -1)" "$(status_call failure)"

reset
echo norecord >"$tmp/lint.mode"
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "a lint that recorded nothing: attest status" "$?" 1
check "a lint that recorded nothing: refusal" "$err" 'attest: make lint recorded nothing; did files change during it?'
check "a lint that recorded nothing posts" "$(calls gh | grep -c statuses)" 0

reset
echo norecord >"$tmp/test.mode"
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "a run that recorded nothing: attest status" "$?" 1
check "a run that recorded nothing: refusal" "$err" 'attest: make test recorded nothing; did files change during it?'
check "a run that recorded nothing posts" "$(calls gh | grep -c statuses)" 0

# ---- post -----------------------------------------------------------------------

reset
in_clone "$attest" post pending 'x' 2>/dev/null
check "post rejects another state" "$?" 2
in_clone "$attest" record build 2>/dev/null
check "record rejects another kind" "$?" 2
in_clone "$attest" record lint -- true 2>/dev/null
check "record rejects a command" "$?" 2
check "a rejected kind records nothing" "$(record_count)" 0
check "a rejected state calls GitHub" "$(calls gh)" ''

in_clone "$attest" post success 'Build & Test' https://example.invalid/run >/dev/null
check "post with a target URL" "$(calls gh)" \
    "api -X POST repos/{owner}/{repo}/statuses/$sha -f state=success -f context=Commit Attestation -f description=Build & Test -f target_url=https://example.invalid/run"

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s attest: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
