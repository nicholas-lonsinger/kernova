#!/usr/bin/env bash
# Fixture tests for Tools/fixture-suites.sh: a passing run is recorded and the
# next run with the same tooling reuses it, from a hook's PATH too; a change to
# a file under each path of the tooling surface, the suite list, the Xcode
# build, or the version of the bash or git on PATH runs the suites again, and
# a change outside the surface does not; an untracked file under the surface,
# a new one or one git stopped tracking, runs them and records nothing until
# git tracks it; and a run whose suite fails, which leaves a decoy's core.bare
# set, during which the tooling changes, or with no Xcode build to read records
# nothing. Runs a copy of the script and the runner inside a fixture clone,
# with stub xcodebuild, sw_vers and dead-code tool installer.

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
mkdir -p "$clone/Tools/lib" "$clone/Tools/tests" "$clone/.githooks" "$clone/.agents" "$clone/App"
cp "$ROOT/Tools/fixture-suites.sh" "$clone/Tools/"
cp "$ROOT/Tools/tests/git-isolation.sh" "$clone/Tools/tests/"
cp "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/attest-records.sh" "$ROOT/Tools/lib/git-isolation.sh" "$clone/Tools/lib/"
printf '#!/bin/bash\necho /nowhere/dead-code-sources\n' >"$clone/Tools/install-dead-code-tool.sh"
# probe.sh logs its run, then fails when $FIXTURE/fail exists and edits the
# tooling when $FIXTURE/edit does.
cat >"$clone/Tools/tests/probe.sh" <<'EOF'
#!/bin/bash
echo run >>"$FIXTURE/runs"
[ ! -e "$FIXTURE/edit" ] || echo edited >>"$FIXTURE/clone/Tools/data"
[ ! -e "$FIXTURE/fail" ]
EOF
# bare.sh passes, leaving core.bare set in the repository its GIT_DIR names.
printf '#!/bin/bash\ngit config core.bare true\n' >"$clone/Tools/tests/bare.sh"
printf '#!/bin/bash\n' >"$clone/Tools/tests/quiet.sh"
chmod +x "$clone/Tools/fixture-suites.sh" "$clone/Tools/install-dead-code-tool.sh"
for path in Tools/data .githooks/hook .agents/skill Makefile .tool-config App/main.swift; do
    echo one >"$clone/$path"
done
git -C "$clone" add -A && git -C "$clone" commit -q -m init

stubs="$tmp/stubs"
mkdir -p "$stubs" "$tmp/other-bash" "$tmp/other-git"
printf '#!/bin/bash\n[ ! -e "$FIXTURE/no-xcode" ] || exit 1\n[ "$*" = -version ] && printf '\''Xcode 27.0\\nBuild version %%s\\n'\'' "$(cat "$FIXTURE/xcode")"\n' >"$stubs/xcodebuild"
printf '#!/bin/bash\n[ "$*" = -buildVersion ] && echo 26Z42\n' >"$stubs/sw_vers"
# A bash and a git that run the real ones and report another version.
printf '#!/bin/sh\n[ "$1" != --version ] || { echo "GNU bash, version 9.9.9(1)-release (stub)"; exit 0; }\nexec %s "$@"\n' \
    "$(command -v bash)" >"$tmp/other-bash/bash"
printf '#!/bin/sh\n[ "$1" != --version ] || { echo "git version 9.9.9 (stub)"; exit 0; }\nexec %s "$@"\n' \
    "$(command -v git)" >"$tmp/other-git/git"
chmod +x "$stubs"/* "$tmp/other-bash/bash" "$tmp/other-git/git"
echo 27A100 >"$tmp/xcode"
export FIXTURE="$tmp" PATH="$stubs:$PATH"

records="$clone/.git/kernova-attest/fixture"
runs() { [ -e "$tmp/runs" ] && grep -c . "$tmp/runs" || echo 0; }
record_count() { find "$records" -type f 2>/dev/null | wc -l | tr -d ' '; }
# step [<suite>...] — the clone's fixture step over probe.sh, or the suites
# given, with $FIRST_ON_PATH first on PATH; its status.
step() {
    [ $# -gt 0 ] || set -- Tools/tests/probe.sh
    (cd "$clone" && PATH="${FIRST_ON_PATH:+$FIRST_ON_PATH:}$PATH" Tools/fixture-suites.sh "$@" >"$tmp/out" 2>&1)
}
said() { grep -cF "$1" "$tmp/out"; }

# ---- record and reuse -------------------------------------------------------------

step
check "an unrecorded tooling: status" "$?" 0
check "an unrecorded tooling runs the suites" "$(runs)" 1
check "a passing run is recorded" "$(record_count)" 1
step
check "a recorded tooling: status" "$?" 0
check "a recorded tooling runs nothing" "$(runs)" 1
check "a recorded tooling says so" "$(said 'fixture suites: reused the pass of ')" 1
# A hook runs with git's exec-path first on PATH, so `git` is the same git
# reached by another path.
FIRST_ON_PATH="$(git --exec-path)" step
check "a run with git's exec-path first on PATH, as in a hook, reuses the pass" "$(runs)" 1

echo two >"$clone/App/main.swift"
echo new >"$clone/App/new.swift"
step
check "a change and a new file outside the tooling reuse the pass" "$(runs)" 1

expected=1
for path in Tools/data .githooks/hook .agents/skill Makefile .tool-config; do
    echo two >>"$clone/$path"
    step
    expected=$((expected + 1))
    check "a change to $path runs the suites" "$(runs)" "$expected"
done
check "each of those passes is recorded" "$(record_count)" 6

# ---- what else the pass rests on ----------------------------------------------------

step Tools/tests/probe.sh Tools/tests/quiet.sh
check "another suite list runs the suites" "$(runs)" 7
echo 27A200 >"$tmp/xcode"
step
check "another Xcode build runs the suites" "$(runs)" 8
FIRST_ON_PATH="$tmp/other-bash" step
check "another bash version on PATH runs the suites" "$(runs)" 9
FIRST_ON_PATH="$tmp/other-git" step
check "another git version on PATH runs the suites" "$(runs)" 10

# ---- what records nothing ----------------------------------------------------------

count=$(record_count)
echo new >"$clone/Tools/new"
step
check "an untracked file under the tooling runs the suites" "$(runs)" 11
check "a run beside an untracked file under the tooling is not recorded" "$(record_count)" "$count"
check "a run beside an untracked file under the tooling says so" \
    "$(said 'not recorded, as untracked files are under the tooling: Tools/new')" 1
step
check "an untracked file under the tooling runs the suites again" "$(runs)" 12
git -C "$clone" add Tools/new
step
check "the file, once tracked, runs the suites" "$(runs)" 13
check "that run is recorded" "$(record_count)" "$((count + 1))"
count=$(record_count)
git -C "$clone" rm -q --cached Tools/new
step
check "a file under the tooling git stopped tracking runs the suites" "$(runs)" 14
check "a run beside a file under the tooling git stopped tracking is not recorded" "$(record_count)" "$count"
git -C "$clone" add Tools/new

count=$(record_count)
touch "$tmp/fail"
echo three >>"$clone/Tools/data"
step
check "a failing suite: status" "$?" 1
check "a failing suite is not recorded" "$(record_count)" "$count"
step
check "a failing suite runs again" "$(runs)" 16
rm "$tmp/fail"

step Tools/tests/bare.sh
check "a passing suite that leaves core.bare set: status" "$?" 1
check "a passing suite that leaves core.bare set is not recorded" "$(record_count)" "$count"

touch "$tmp/edit"
step
check "a run during which the tooling changes: status" "$?" 0
check "a run during which the tooling changes is not recorded" "$(record_count)" "$count"
check "a run during which the tooling changes says so" "$(said 'not recorded, as the tooling changed during the run')" 1
rm "$tmp/edit"

touch "$tmp/no-xcode"
step
check "a run with no Xcode build to read: status" "$?" 0
check "a run with no Xcode build to read runs the suites" "$(runs)" 18
check "a run with no Xcode build to read is not recorded" "$(record_count)" "$count"
check "a run with no Xcode build to read says so" \
    "$(said 'not recorded, as the tooling or the Xcode or macOS build it would be recorded under cannot be read')" 1
rm "$tmp/no-xcode"

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s fixture-suites: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
