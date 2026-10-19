#!/usr/bin/env bash
# Fixture tests for Tools/attest.sh: `record` passes its command through and
# records only a passing run whose fingerprint held, the clean-tree content
# tree is HEAD's, `attest` refuses a dirty or unpushed HEAD before any test,
# reuses a record or runs `make test` and posts only on a record, and `post`
# takes only success or failure. Runs in a fixture clone with stub xcodebuild,
# sw_vers, gh, and make.

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
mkdir -p "$clone/Tools" "$clone/Config"
cp "$ROOT/Tools/attest.sh" "$clone/Tools/"
printf 'Config/Local.xcconfig\n' >"$clone/.gitignore"
echo one >"$clone/file"
git -C "$clone" add -A && git -C "$clone" commit -q -m init
attest="$clone/Tools/attest.sh"
records="$clone/.git/kernova-tests"

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
# make test as $FIXTURE/make.mode says: a recorded pass, a failure, or a pass
# that records nothing.
cat >"$stubs/make" <<'EOF'
#!/bin/bash
echo "$*" >>"$FIXTURE/make.log"
case "$(cat "$FIXTURE/make.mode")" in
    record) exec "$ATTEST" record -- true ;;
    fail) exit 2 ;;
    norecord) exit 0 ;;
esac
EOF
chmod +x "$stubs"/*
export FIXTURE="$tmp" ATTEST="$attest" MAKE="$stubs/make" PATH="$stubs:$PATH"

reset() { rm -rf "$records" "$tmp/gh.log" "$tmp/make.log"; }
record_count() { find "$records" -type f 2>/dev/null | wc -l | tr -d ' '; }
record_line() { awk -v key="$1" '$1 == key { print $2 }' "$records"/* 2>/dev/null; }
calls() { cat "$tmp/$1.log" 2>/dev/null; }
in_clone() { (cd "$clone" && "$@"); }

# ---- record ---------------------------------------------------------------------

reset
out=$(in_clone "$attest" record -- sh -c 'echo out; echo err >&2' 2>"$tmp/err")
check "record passes stdout through" "$out" out
check "record passes stderr through" "$(cat "$tmp/err")" err
check "a passing run is recorded" "$(record_count)" 1
check "the clean tree's content tree is HEAD's" "$(record_line tree)" "$(git -C "$clone" rev-parse 'HEAD^{tree}')"
check "the record's Xcode build" "$(record_line xcode)" 27A100
check "the record's macOS build" "$(record_line macos)" 26Z42
check "the record without Config/Local.xcconfig" "$(record_line local-xcconfig)" none
check "the record's date" "$(record_line date | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" 1

reset
in_clone "$attest" record -- sh -c 'exit 3'
check "a failing run's status" "$?" 3
check "a failing run is not recorded" "$(record_count)" 0

reset
in_clone "$attest" record -- sh -c 'echo changed >file' 2>"$tmp/err"
check "a run that changes files keeps its status" "$?" 0
check "a run that changes files is not recorded" "$(record_count)" 0
check "a run that changes files says so" "$(cat "$tmp/err")" 'attest: the files changed during the run, so it is not recorded'
git -C "$clone" checkout -q -- file

reset
echo dirty >"$clone/untracked"
index_before=$(shasum "$clone/.git/index")
in_clone "$attest" record -- true
check "a dirty tree is recorded" "$(record_count)" 1
check "a dirty tree's content tree" "$(record_line tree)" \
    "$(cd "$clone" && cp .git/index "$tmp/index" && GIT_INDEX_FILE="$tmp/index" git add -A && GIT_INDEX_FILE="$tmp/index" git write-tree)"
check "a dirty tree's content tree is not HEAD's" "$([ "$(record_line tree)" != "$(git -C "$clone" rev-parse 'HEAD^{tree}')" ] && echo differs || echo same)" differs
check "the real index is untouched" "$(shasum "$clone/.git/index")" "$index_before"
rm "$clone/untracked"

reset
echo 'DEVELOPMENT_TEAM = X' >"$clone/Config/Local.xcconfig"
in_clone "$attest" record -- true
check "the record with Config/Local.xcconfig" "$(record_line local-xcconfig)" "$(git hash-object "$clone/Config/Local.xcconfig")"
rm "$clone/Config/Local.xcconfig"

reset
mkdir -p "$records"
touch -t 202001010000 "$records/stale"
in_clone "$attest" record -- true
check "a write prunes records over 30 days old" "$([ -e "$records/stale" ] && echo kept || echo pruned)" pruned
check "a write keeps its own record" "$(record_count)" 1

reset
touch "$records"
in_clone "$attest" record -- true 2>"$tmp/err"
check "a run whose record cannot be written keeps its status" "$?" 0
check "a run whose record cannot be written says so" "$(grep -c 'cannot write the record' "$tmp/err")" 1
rm -f "$records"

# ---- attest ---------------------------------------------------------------------

sha=$(git -C "$clone" rev-parse HEAD)
status_call() { printf 'api -X POST repos/{owner}/{repo}/statuses/%s -f state=%s -f context=Test Attestation -f description=make attest: Xcode 27A100, macOS 26Z42' "$sha" "$1"; }

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
in_clone "$attest" record -- true
out=$(in_clone "$attest")
check "a recorded HEAD's attest status" "$?" 0
check "a recorded HEAD says it reused the run" "$(printf '%s\n' "$out" | grep -c '^attest: reusing the passing make test of ')" 1
check "a recorded HEAD runs make" "$(calls make)" ''
check "a recorded HEAD posts success" "$(calls gh | tail -1)" "$(status_call success)"

reset
echo record >"$tmp/make.mode"
in_clone "$attest" >/dev/null
check "an unrecorded HEAD's attest status" "$?" 0
check "an unrecorded HEAD runs make test" "$(calls make)" test
check "a passing run posts success" "$(calls gh | tail -1)" "$(status_call success)"

reset
echo fail >"$tmp/make.mode"
in_clone "$attest" >/dev/null
check "a failing run's attest status" "$?" 1
check "a failing run posts failure" "$(calls gh | tail -1)" "$(status_call failure)"

reset
echo norecord >"$tmp/make.mode"
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "a run that recorded nothing: attest status" "$?" 1
check "a run that recorded nothing: refusal" "$err" 'attest: the run recorded nothing; did files change during it?'
check "a run that recorded nothing posts" "$(calls gh | grep -c statuses)" 0

# ---- post -----------------------------------------------------------------------

reset
in_clone "$attest" post pending 'x' 2>/dev/null
check "post rejects another state" "$?" 2
check "a rejected state calls GitHub" "$(calls gh)" ''

in_clone "$attest" post success 'Build & Test' https://example.invalid/run >/dev/null
check "post with a target URL" "$(calls gh)" \
    "api -X POST repos/{owner}/{repo}/statuses/$sha -f state=success -f context=Test Attestation -f description=Build & Test -f target_url=https://example.invalid/run"

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s attest: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
