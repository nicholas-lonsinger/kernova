#!/usr/bin/env bash
# Fixture tests for Tools/attest.sh: `record <kind>` runs Tools/<kind>.sh, passes
# its output and status through and records only a passing run whose
# fingerprint held, never a lint run beside an untracked file; the clean-tree
# content tree is HEAD's; a test-linux run is handed the content tree, and its
# fingerprint follows the Linux tests' inputs and nothing else; the Makefile's
# `lint`, `test` and `test-linux` record a passing run of their script under
# plain make and nothing under `make -n` or over a failing script under
# `make -i`, `make test` passes its script nothing whatever variables the
# command line sets and refuses a configuration other than Debug; `attest`
# refuses a dirty or unpushed HEAD before any run, reuses the lint, test-linux
# and test records or runs those it lacks and posts success only on all three,
# and when the Linux tests lack a record and cannot run — before any run, or
# as Tools/test-linux.sh's exit 3 — names what is missing and posts nothing;
# and `post` takes only success or failure. Runs in a fixture clone with stub
# xcodebuild, sw_vers, gh, container, sysctl and the three scripts, and the
# real make for the Makefile's own recipes.

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
mkdir -p "$clone/Tools/lib" "$clone/Config" "$clone/KernovaKit"
cp "$ROOT/Tools/attest.sh" "$ROOT/Tools/checkout-lock.sh" "$clone/Tools/"
cp "$ROOT/Tools/lib/attest-records.sh" "$ROOT/Tools/lib/linux-tests.sh" "$ROOT/Tools/lib/swift-roots.sh" \
    "$ROOT/Tools/lib/xcodebuild-flags.sh" "$clone/Tools/lib/"
cp "$ROOT/Makefile" "$clone/"
# Tools/lint.sh, Tools/test.sh and Tools/test-linux.sh log their run,
# arguments included, then run $FIXTURE/<kind>.run.
for script in lint test test-linux; do
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
echo 9.8.7 >"$clone/.swift-version"
echo kit >"$clone/KernovaKit/Package.swift"
echo 'FROM ${BASE}' >"$clone/Tools/linux-tests.Containerfile"
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
# container logs each call but --version; `system status`, `system start`,
# `image inspect` and `build` exit their files' statuses, and the store is
# empty.
cat >"$stubs/container" <<'EOF'
#!/bin/bash
[ "$*" = --version ] && { echo 'container CLI version 9.9.9 (build: release, commit: fixture)'; exit 0; }
echo "$*" >>"$FIXTURE/container.log"
case "$*" in
    'system status') exit "$(cat "$FIXTURE/status.status")" ;;
    'system start'*) exit "$(cat "$FIXTURE/start.status")" ;;
    'image inspect'*) exit "$(cat "$FIXTURE/inspect.status")" ;;
    'image list'*) echo '[]' ;;
    build*) exit "$(cat "$FIXTURE/build.status")" ;;
esac
EOF
cat >"$stubs/sysctl" <<'EOF'
#!/bin/bash
[ "$*" = '-n kern.hv_support' ] && cat "$FIXTURE/hv"
EOF
chmod +x "$stubs"/*
# Every directory on PATH but those holding a container, so the stub is the
# only one and moving it away leaves none.
bare_path=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r dir; do [ -x "$dir/container" ] || printf '%s:' "$dir"; done)
export FIXTURE="$tmp" PATH="$stubs:${bare_path%:}"

reset() {
    rm -rf "$records" "$tmp/gh.log" "$tmp/ran.log" "$tmp/container.log"
    for kind in lint test test-linux; do echo 'exit 0' >"$tmp/$kind.run"; done
    for file in status start inspect build; do echo 0 >"$tmp/$file.status"; done
    echo 1 >"$tmp/hv"
}
# runs <kind> <bash> — what Tools/<kind>.sh does after logging its run.
runs() { printf '%s\n' "$2" >"$tmp/$1.run"; }
record_count() { find "$records" -type f 2>/dev/null | wc -l | tr -d ' '; }
record_line() { awk -v key="$1" '$1 == key { print $2 }' "$records"/*/* 2>/dev/null; }
# linux_line <key> — the value of <key> in the test-linux record, past the key.
linux_line() { awk -v key="$1" '$1 == key { sub(/^[^ ]* /, ""); print }' "$records"/test-linux/* 2>/dev/null; }
linux_count() { find "$records/test-linux" -type f 2>/dev/null | wc -l | tr -d ' '; }
calls() { cat "$tmp/$1.log" 2>/dev/null; }
# kinds_ran — the kinds whose script ran, in order, since the log was cleared.
kinds_ran() { calls ran | awk '{ printf "%s ", $1 }'; }
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
check "a lint run beside an untracked file keeps its status" "$?" 0
check "a lint run beside an untracked file runs Tools/lint.sh" "$(calls ran)" lint
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

# ---- record test-linux -------------------------------------------------------------

head_tree=$(git -C "$clone" rev-parse 'HEAD^{tree}')
# The tree of the clone's Linux test inputs, from a repository holding copies
# of them alone.
inputs_repo="$tmp/inputs"
git init -q "$inputs_repo"
for f in .swift-version KernovaKit/Package.swift Tools/lib/linux-tests.sh Tools/linux-tests.Containerfile Tools/test-linux.sh; do
    mkdir -p "$inputs_repo/$(dirname "$f")" && cp -p "$clone/$f" "$inputs_repo/$f"
done
inputs_tree=$(git -C "$inputs_repo" add -A && git -C "$inputs_repo" write-tree)

reset
in_clone "$attest" record test-linux
check "record runs Tools/test-linux.sh over the content tree" "$(calls ran)" "test-linux $head_tree"
check "a passing Linux run is recorded" "$(linux_count)" 1
check "the Linux record's tree holds the Linux test inputs alone" "$(linux_line linux-tests)" "$inputs_tree"
check "the Linux record's container release" "$(linux_line container)" 'container CLI version 9.9.9 (build: release, commit: fixture)'
check "the Linux record names no Xcode or macOS build" "$(cat "$records"/test-linux/* | grep -cE '^(xcode|macos) ')" 0

echo two >"$clone/file"
in_clone "$attest" record test-linux
check "an app-only edit keeps the Linux fingerprint" "$(linux_count)" 1
echo edited >"$clone/KernovaKit/Package.swift"
in_clone "$attest" record test-linux
check "a KernovaKit edit makes a new Linux fingerprint" "$(linux_count)" 2
git -C "$clone" checkout -q -- file KernovaKit/Package.swift

reset
runs test-linux 'echo three >"$FIXTURE/clone/file"'
in_clone "$attest" record test-linux
check "a Linux run during an app-only edit is recorded" "$(linux_count)" 1
git -C "$clone" checkout -q -- file

reset
runs test-linux 'echo edited >"$FIXTURE/clone/KernovaKit/Package.swift"'
in_clone "$attest" record test-linux 2>/dev/null
check "a Linux run during an input edit is not recorded" "$(linux_count)" 0
git -C "$clone" checkout -q -- KernovaKit/Package.swift

reset
runs test-linux 'exit 4'
in_clone "$attest" record test-linux
check "a failing Linux run's status" "$?" 4
check "a failing Linux run is not recorded" "$(linux_count)" 0

reset
mv "$stubs/container" "$tmp/container.away"
err=$(in_clone "$attest" record test-linux 2>&1 >/dev/null)
check "a Linux run without container says only what its script says" "$err" ''
mv "$tmp/container.away" "$stubs/container"

# ---- make lint, make test, make test-linux -------------------------------------------

# make_in_clone <make argument>... — the clone's Makefile under the real make,
# with nothing inherited from a make that runs this suite.
make_in_clone() {
    (cd "$clone" && env -u MAKE -u MAKEFLAGS -u MFLAGS -u MAKELEVEL "$real_make" --no-print-directory "$@" >/dev/null 2>&1)
}

# ran <kind> — what Tools/<kind>.sh logs for its run on the clean clone.
ran() { if [ "$1" = test-linux ]; then echo "test-linux $head_tree"; else echo "$1"; fi; }

for kind in lint test test-linux; do
    reset
    make_in_clone "$kind"
    check "make $kind runs Tools/$kind.sh" "$(calls ran)" "$(ran "$kind")"
    check "make $kind records a passing run" "$(record_count)" 1

    reset
    make_in_clone -n "$kind"
    check "make -n $kind runs Tools/$kind.sh" "$(calls ran)" ''
    check "make -n $kind records" "$(record_count)" 0

    reset
    runs "$kind" 'exit 1'
    make_in_clone -i "$kind"
    check "make -i $kind runs Tools/$kind.sh" "$(calls ran)" "$(ran "$kind")"
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
status_call() { printf 'api -X POST repos/{owner}/{repo}/statuses/%s -f state=%s -f context=Commit Attestation -f description=make attest: Xcode 27A100, macOS 26Z42, Linux on swift:9.8.7-noble' "$sha" "$1"; }
# record_all — a passing record of each kind for the clone as it is.
record_all() { for kind in lint test-linux test; do in_clone "$attest" record "$kind"; done; }

reset
touch "$tmp/pushed"
echo dirty >"$clone/untracked"
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "a dirty tree's attest status" "$?" 1
check "a dirty tree's refusal" "$err" 'attest: attest certifies HEAD; commit or stash first'
check "a dirty tree calls GitHub" "$(calls gh)" ''
check "a dirty tree runs anything" "$(kinds_ran)" ''
rm "$clone/untracked"

reset
rm -f "$tmp/pushed"
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "an unpushed HEAD's attest status" "$?" 1
check "an unpushed HEAD's refusal" "$err" "attest: GitHub does not have $sha; push first"
check "an unpushed HEAD runs anything" "$(kinds_ran)" ''
touch "$tmp/pushed"

reset
record_all
rm "$tmp/ran.log"
echo 1 >"$tmp/status.status"
out=$(in_clone "$attest")
check "a recorded HEAD's attest status" "$?" 0
for kind in lint test-linux test; do
    check "a recorded HEAD says it reused the $kind run" "$(printf '%s\n' "$out" | grep -c "^attest: reusing the passing make $kind of ")" 1
done
check "a recorded HEAD runs anything" "$(kinds_ran)" ''
check "a recorded HEAD leaves container's service alone" "$(calls container)" ''
check "a recorded HEAD posts success" "$(calls gh | tail -1)" "$(status_call success)"

reset
in_clone "$attest" record test
in_clone "$attest" record test-linux
rm "$tmp/ran.log"
in_clone "$attest" >/dev/null
check "a HEAD with test and Linux records: attest status" "$?" 0
check "a HEAD with test and Linux records runs lint" "$(kinds_ran)" 'lint '
check "a HEAD with test and Linux records posts success" "$(calls gh | tail -1)" "$(status_call success)"

reset
in_clone "$attest" record lint
in_clone "$attest" record test
rm "$tmp/ran.log"
in_clone "$attest" >/dev/null
check "a HEAD without a Linux record runs the Linux tests" "$(kinds_ran)" 'test-linux '
check "a HEAD without a Linux record posts success" "$(calls gh | tail -1)" "$(status_call success)"

reset
in_clone "$attest" >/dev/null
check "an unrecorded HEAD's attest status" "$?" 0
check "an unrecorded HEAD runs lint, the Linux tests, then the tests" "$(kinds_ran)" 'lint test-linux test '
check "a passing run posts success" "$(calls gh | tail -1)" "$(status_call success)"

# A commit that changes app code alone reruns lint and the tests and reuses
# the Linux tests; one that changes KernovaKit reruns all three.
reset
record_all
echo four >"$clone/file"
git -C "$clone" commit -q -am 'app only'
sha=$(git -C "$clone" rev-parse HEAD)
rm "$tmp/ran.log"
in_clone "$attest" >/dev/null
check "an app-only commit reruns lint and the tests alone" "$(kinds_ran)" 'lint test '
rm "$tmp/ran.log"
echo kit2 >"$clone/KernovaKit/Package.swift"
git -C "$clone" commit -q -am 'KernovaKit'
sha=$(git -C "$clone" rev-parse HEAD)
in_clone "$attest" >/dev/null
check "a KernovaKit commit reruns all three" "$(kinds_ran)" 'lint test-linux test '
git -C "$clone" reset -q --hard HEAD~2
sha=$(git -C "$clone" rev-parse HEAD)

# cannot_run <name> <message> — attest with no Linux record, as set up, fails
# naming what is missing and the `ci` route, before any run or post.
ci_route="Where they cannot run, label the PR \`ci\`: CI then lints and runs both test suites on each push, and posts Commit Attestation."
cannot_run() {
    in_clone "$attest" record lint
    in_clone "$attest" record test
    rm "$tmp/ran.log"
    err=$(in_clone "$attest" 2>&1 >/dev/null)
    check "$1: attest status" "$?" 1
    check "$1: refusal" "$(printf '%s\n' "$err" | tail -1)" "attest: the Linux tests need $2. $ci_route"
    check "$1 runs anything" "$(kinds_ran)" ''
    check "$1 posts" "$(calls gh | grep -c statuses)" 0
}

reset
mv "$stubs/container" "$tmp/container.away"
cannot_run 'no container' "Apple's container, which \`make setup\` installs with Homebrew"
mv "$tmp/container.away" "$stubs/container"

reset
echo 0 >"$tmp/hv"
cannot_run 'no hypervisor' 'a hypervisor for container to run Linux in: this Mac has none (sysctl kern.hv_support is not 1)'

reset
echo 1 >"$tmp/status.status"
echo 1 >"$tmp/start.status"
cannot_run 'a service that will not start' "container's service, which \`container system start\` did not start"

reset
echo 1 >"$tmp/inspect.status"
echo 1 >"$tmp/build.status"
cannot_run 'an image that will not build' \
    "their image $(cd "$clone" && . Tools/lib/linux-tests.sh && linux_tests_image HEAD), which \`container build\` did not build on docker.io/library/swift:9.8.7-noble (its output is above)"

# Tools/test-linux.sh's exit 3: the tests could not run after all.
reset
runs test-linux 'exit 3'
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "a Linux run that could not run: attest status" "$?" 1
check "a Linux run that could not run: refusal" "$(printf '%s\n' "$err" | tail -1)" "attest: the Linux tests could not run, as said above. $ci_route"
check "a Linux run that could not run stops after it" "$(kinds_ran)" 'lint test-linux '
check "a Linux run that could not run posts" "$(calls gh | grep -c statuses)" 0

reset
echo 1 >"$tmp/status.status"
in_clone "$attest" >/dev/null 2>&1
check "a stopped service is started before any run" "$(calls container | head -2 | tr '\n' ' ')" 'system status system start --enable-kernel-install '
check "a started service lets attest post success" "$(calls gh | tail -1)" "$(status_call success)"

reset
runs test-linux 'exit 1'
in_clone "$attest" >/dev/null
check "a failing Linux run's attest status" "$?" 1
check "a failing Linux run posts failure" "$(calls gh | tail -1)" "$(status_call failure)"
check "a failing Linux run stops before the tests" "$(kinds_ran)" 'lint test-linux '

reset
runs test-linux 'echo edited >"$FIXTURE/clone/KernovaKit/Package.swift"'
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "a Linux run that recorded nothing: refusal" "$(printf '%s\n' "$err" | tail -1)" 'attest: this test-linux run recorded nothing; did files change during it?'
check "a Linux run that recorded nothing posts" "$(calls gh | grep -c statuses)" 0
git -C "$clone" checkout -q -- KernovaKit/Package.swift

reset
in_clone "$attest" record test
runs lint 'exit 1'
in_clone "$attest" >/dev/null
check "a failing lint's attest status" "$?" 1
check "a failing lint posts failure" "$(calls gh | tail -1)" "$(status_call failure)"
check "a failing lint posts once" "$(calls gh | grep -c statuses)" 1

reset
runs test 'exit 1'
in_clone "$attest" >/dev/null
check "a failing test run's attest status" "$?" 1
check "a failing test run posts failure" "$(calls gh | tail -1)" "$(status_call failure)"

reset
runs lint 'echo changed >"$FIXTURE/clone/file"'
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "a lint that recorded nothing: attest status" "$?" 1
check "a lint that recorded nothing: refusal" "$(printf '%s\n' "$err" | tail -1)" 'attest: this lint run recorded nothing; did files change during it?'
check "a lint that recorded nothing posts" "$(calls gh | grep -c statuses)" 0
git -C "$clone" checkout -q -- file

reset
in_clone "$attest" record lint
runs test 'echo changed >"$FIXTURE/clone/file"'
err=$(in_clone "$attest" 2>&1 >/dev/null)
check "a run that recorded nothing: attest status" "$?" 1
check "a run that recorded nothing: refusal" "$(printf '%s\n' "$err" | tail -1)" 'attest: this test run recorded nothing; did files change during it?'
check "a run that recorded nothing posts" "$(calls gh | grep -c statuses)" 0
git -C "$clone" checkout -q -- file

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
