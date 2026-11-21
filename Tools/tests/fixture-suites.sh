#!/usr/bin/env bash
# Fixture tests for Tools/fixture-suites.sh: a suite's stage index holds the
# suite and its declared reads, the runner and its declared reads, and the
# root's dotfiles, and the suite inherits no variable naming the checkout; a
# file outside them read as data, sourced or run fails the suite and records
# nothing though the suite passed, as does a passing suite that sets core.bare
# through its inherited GIT_DIR; a passing suite is recorded and, with --reuse,
# not run again until a file in its reads changes or is added, or the Xcode
# build, the bash or the git changes, while a change outside them reuses the
# pass; a failing suite records nothing; and only a stage holding
# Tools/install-dead-code-tool.sh gets the dead-code-sources it installs, whose
# reads count as the suite's. Runs a copy of the runner and the files its
# header declares inside a fixture clone, with stub xcodebuild and sw_vers.
#
# fixture reads: Tools/fixture-suites.sh

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
# shellcheck source=../lib/fixture-reads.sh
. "$ROOT/Tools/lib/fixture-reads.sh"

# The clone holds the runner and exactly the files its header declares, so a
# file the runner reads without declaring fails every check below.
clone="$tmp/clone"
git init -q -b main "$clone"
runner_files=(Tools/fixture-suites.sh)
while IFS= read -r path; do runner_files+=("$path"); done < <(fixture_reads "$ROOT/Tools/fixture-suites.sh")
for path in "${runner_files[@]}"; do
    mkdir -p "$clone/$(dirname "$path")" && cp "$ROOT/$path" "$clone/$path"
done

# probe.sh logs each run, with what its stage's index holds and what it
# inherited, reads data/a.txt, and then as files under $FIXTURE say: reads
# other.txt as data, sources lib/helper.sh with a plain `.`, or runs
# lib/tool.sh — each outside its reads and none of them able to fail it — or
# fails.
mkdir -p "$clone/Tools/tests" "$clone/data" "$clone/lib"
cat >"$clone/Tools/tests/probe.sh" <<'EOF'
#!/usr/bin/env bash
# A suite that reads data/.
#
# fixture reads: data
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
{
    echo run
    # shellcheck disable=SC2046 # one variable name per word
    printf 'tracked %s\n' $(unset $(git rev-parse --local-env-vars); git -C "$ROOT" ls-files)
    [ -z "${LEAK+set}" ] || echo "inherited LEAK=$LEAK"
    clone=$(cat "$FIXTURE/clone-path")
    case "${OLDPWD-}" in "$clone" | "$clone"/*) echo "inherited OLDPWD=$OLDPWD" ;; esac
    case ":$PATH:" in *":$clone/bin:"*) echo 'inherited a PATH entry in the checkout' ;; esac
    echo "dead-code-sources ${KERNOVA_FIXTURE_DEAD_CODE_SOURCES-unset}"
} >>"$FIXTURE/probe.log"
cat "$ROOT/data/a.txt" >/dev/null || exit 1
[ ! -e "$FIXTURE/read-data" ] || cat "$ROOT/other.txt" >/dev/null 2>&1 || :
[ ! -e "$FIXTURE/read-source" ] || . "$ROOT/lib/helper.sh"
[ ! -e "$FIXTURE/read-run" ] || "$ROOT/lib/tool.sh" >/dev/null 2>&1 || :
[ ! -e "$FIXTURE/fail" ]
EOF
printf 'helper=1\n' >"$clone/lib/helper.sh"
printf '#!/bin/sh\nexit 3\n' >"$clone/lib/tool.sh"
# bare-probe.sh sets core.bare in the repository its inherited GIT_DIR names,
# and passes.
cat >"$clone/Tools/tests/bare-probe.sh" <<'EOF'
#!/usr/bin/env bash
# A suite that leaks into its caller's repository.
git config core.bare true
EOF
# tool-probe.sh's stage holds an installer whose output names where it ran,
# and which reads other.txt when $FIXTURE/installer-reads exists.
cat >"$clone/Tools/tests/tool-probe.sh" <<'EOF'
#!/usr/bin/env bash
# A suite that reads the dead-code tool installer.
#
# fixture reads: Tools/install-dead-code-tool.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "${KERNOVA_FIXTURE_DEAD_CODE_SOURCES-unset}" = "$ROOT/Tools/dead-code-sources" ] && echo stage || echo other
EOF
cat >"$clone/Tools/install-dead-code-tool.sh" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$FIXTURE/installer-reads" ] || cat "$(dirname "$0")/../other.txt" >/dev/null
[ "$*" = dead-code-sources ] && printf '%s/dead-code-sources\n' "$(cd "$(dirname "$0")" && pwd)"
EOF
chmod +x "$clone/Tools/tests"/*.sh "$clone/Tools/install-dead-code-tool.sh" "$clone/lib/tool.sh"
echo a >"$clone/data/a.txt"
echo other >"$clone/other.txt"
echo dot >"$clone/.dotfile"
git -C "$clone" add -A && git -C "$clone" commit -q -m init

stubs="$tmp/stubs"
mkdir -p "$stubs" "$clone/bin" "$tmp/other-bash" "$tmp/other-git"
printf '#!/bin/bash\n[ "$*" = -version ] && printf '\''Xcode 27.0\\nBuild version %%s\\n'\'' "$(cat "$FIXTURE/xcode")"\n' >"$stubs/xcodebuild"
printf '#!/bin/bash\n[ "$*" = -buildVersion ] && echo 26Z42\n' >"$stubs/sw_vers"
chmod +x "$stubs"/*
ln -s "$(command -v bash)" "$tmp/other-bash/bash"
ln -s "$(command -v git)" "$tmp/other-git/git"
echo 27A100 >"$tmp/xcode"
printf '%s\n' "$clone" >"$tmp/clone-path"
export FIXTURE="$tmp" PATH="$stubs:$clone/bin:$PATH"

records="$clone/.git/kernova-attest/fixture"
runs() { awk '$0 == "run" { n++ } END { print n + 0 }' "$tmp/probe.log"; }
record_count() { find "$records" -type f 2>/dev/null | wc -l | tr -d ' '; }
# runner [<argument>...] — the clone's runner on probe.sh, with a variable
# naming the clone and a dead-code-sources exported, and $FIRST_ON_PATH first
# on PATH; its status.
runner() {
    (cd "$clone" && LEAK="$clone/x" KERNOVA_FIXTURE_DEAD_CODE_SOURCES=/elsewhere PATH="${FIRST_ON_PATH:+$FIRST_ON_PATH:}$PATH" \
        bash Tools/fixture-suites.sh "$@" Tools/tests/probe.sh >"$tmp/out" 2>&1)
}
told() { grep -cF "$1" "$tmp/out"; }

# ---- what a stage holds -------------------------------------------------------

runner --reuse
check "an unrecorded suite: status" "$?" 0
check "an unrecorded suite runs" "$(runs)" 1
check "its stage's index holds the suite and its reads, the runner and its reads, and the root's dotfiles" \
    "$(sed -n 's/^tracked //p' "$tmp/probe.log" | tr '\n' ' ')" \
    "$(printf '%s\n' .dotfile Tools/tests/probe.sh data/a.txt "${runner_files[@]}" | LC_ALL=C sort | tr '\n' ' ')"
check "it inherits no variable naming the checkout" "$(grep -c '^inherited' "$tmp/probe.log")" 0
check "a stage without the installer gets no dead-code-sources, whatever the caller exported" \
    "$(sed -n 's/^dead-code-sources //p' "$tmp/probe.log")" unset
check "a passing suite is recorded" "$(record_count)" 1

# ---- reads outside its declaration ------------------------------------------------

# outside <flag> <path> <how> — the suite, reading <path> as <flag> says,
# without its header declaring it: fails, naming the path, and records nothing.
outside() {
    local count
    count=$(record_count)
    touch "$tmp/$1"
    echo "$1" >>"$clone/data/a.txt"
    runner --reuse
    check "a file $3 outside its reads: status" "$?" 1
    check "a file $3 outside its reads is named" "$(told "Tools/tests/probe.sh: read what its header does not declare: $2")" 1
    check "a file $3 outside its reads is not recorded" "$(record_count)" "$count"
    rm "$tmp/$1"
}
outside read-data other.txt 'read as data'
outside read-source lib/helper.sh 'sourced with a plain .'
outside read-run lib/tool.sh 'run'

touch "$tmp/installer-reads"
out=$(cd "$clone" && bash Tools/fixture-suites.sh Tools/tests/tool-probe.sh 2>&1)
check "a file read outside its reads by the installer it declares is named" \
    "$(printf '%s\n' "$out" | grep -cF 'Tools/tests/tool-probe.sh: read what its header does not declare: other.txt')" 1
rm "$tmp/installer-reads"

# ---- the decoy ------------------------------------------------------------------

count=$(record_count)
out=$(cd "$clone" && bash Tools/fixture-suites.sh Tools/tests/bare-probe.sh 2>&1)
check "a passing suite that sets core.bare in its caller's repository: status" "$?" 1
check "a passing suite that sets core.bare in its caller's repository is told so" \
    "$(printf '%s\n' "$out" | grep -cF "Tools/tests/bare-probe.sh: set core.bare 'true'")" 1
check "a passing suite that sets core.bare in its caller's repository is not recorded" "$(record_count)" "$count"

# ---- reuse --------------------------------------------------------------------

runner --reuse
runner --reuse
check "a recorded suite is not run" "$(runs)" 5
check "a recorded suite says so" "$(told 'reused the recorded pass of 1 whose stage is unchanged')" 1

runner
check "a recorded suite runs without --reuse" "$(runs)" 6

echo changed >"$clone/other.txt"
runner --reuse
check "a change outside its reads reuses its pass" "$(runs)" 6

echo changed >"$clone/data/a.txt"
runner --reuse
check "a change to a tracked file in its reads runs it" "$(runs)" 7
runner --reuse
check "that run's pass is reused" "$(runs)" 7

echo new >"$clone/data/new.txt"
runner --reuse
check "a new file in its reads runs it" "$(runs)" 8
check "a new file is in its stage's index" "$(grep -c '^tracked data/new.txt$' "$tmp/probe.log")" 1
runner --reuse
check "the pass with a new file present is reused" "$(runs)" 8

echo 27A200 >"$tmp/xcode"
runner --reuse
check "a changed Xcode build runs it" "$(runs)" 9

FIRST_ON_PATH="$tmp/other-bash" runner --reuse
check "another bash on PATH runs it" "$(runs)" 10
FIRST_ON_PATH="$tmp/other-git" runner --reuse
check "another git on PATH runs it" "$(runs)" 11

touch "$tmp/fail"
echo failing >"$clone/data/a.txt"
count=$(record_count)
runner --reuse
check "a failing suite: status" "$?" 1
check "a failing suite is not recorded" "$(record_count)" "$count"
runner --reuse
check "a failing suite runs again" "$(runs)" 13
rm "$tmp/fail"

# ---- declarations ---------------------------------------------------------------

perl -pi -e 's/^# fixture reads: data\n/# fixture reads: data missing\n/' "$clone/Tools/tests/probe.sh"
runner --reuse
check "a declared path not in the checkout: status" "$?" 1
check "a declared path not in the checkout is named" "$(told 'not in the checkout: missing')" 1
check "a suite with a declared path not in the checkout does not run" "$(runs)" 13
git -C "$clone" checkout -q -- Tools/tests/probe.sh

out=$(cd "$clone" && KERNOVA_FIXTURE_DEAD_CODE_SOURCES=/elsewhere bash Tools/fixture-suites.sh Tools/tests/tool-probe.sh 2>&1)
check "a stage holding the installer gets the dead-code-sources it installs" "$(printf '%s\n' "$out" | grep -cx stage)" 1

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s fixture-suites: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
