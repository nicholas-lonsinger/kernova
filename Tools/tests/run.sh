#!/usr/bin/env bash
# Fixture tests for Tools/check.sh and Tools/xcresult-report.sh. Replays the
# recorded xcodebuild logs and result-bundle JSON under fixtures/ through fakes
# of `make`, `xcrun`, and `xcodebuild` placed first on PATH, so every verdict
# path is exercised without Xcode. `make lint` runs it; it takes under a second.
#
# Fixture placeholders: @ROOT@ is this checkout's root (the scripts rewrite it
# repo-relative), @BUNDLE@ the directory holding the fake .xcresult bundles.
# A fake bundle is an empty directory; the fake xcresulttool answers for it
# from fixtures/xcresult/<bundle name>/{summary,tests}.json.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
FIX="$ROOT/Tools/tests/fixtures"

# shellcheck source=../lib/output.sh
. "$ROOT/Tools/lib/output.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/nox" "$tmp/logs" "$tmp/out" \
    "$tmp/bundles/failed.xcresult" "$tmp/bundles/passed.xcresult" "$tmp/bundles/empty.xcresult"

for f in "$FIX"/logs/*.log; do
    sed "s#@ROOT@#$ROOT#g; s#@BUNDLE@#$tmp/bundles#g" "$f" >"$tmp/logs/$(basename "$f")"
done

printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/xcodebuild"
cat >"$tmp/bin/make" <<'FAKE'
#!/bin/sh
# Replays $FAKE_MAKE_LOG and exits $FAKE_MAKE_STATUS, whatever the target.
cat "$FAKE_MAKE_LOG"
exit "${FAKE_MAKE_STATUS:-0}"
FAKE
cat >"$tmp/bin/xcrun" <<'FAKE'
#!/bin/sh
# xcrun xcresulttool get test-results <summary|tests> --path <bundle> --format json
[ "$1" = xcresulttool ] || { echo "fake xcrun: unexpected $*" >&2; exit 1; }
kind="$4"
path=
while [ $# -gt 0 ]; do
    [ "$1" = --path ] && path="$2"
    shift
done
fixture="$FAKE_XCRESULT_FIXTURES/$(basename "$path")/$kind.json"
[ -f "$fixture" ] || { echo "fake xcresulttool: no fixture for $path ($kind)" >&2; exit 1; }
sed "s#@ROOT@#$FAKE_ROOT#g" "$fixture"
FAKE
chmod +x "$tmp/bin"/*
# A PATH with no xcodebuild at all: macOS keeps an xcode-select shim at
# /usr/bin/xcodebuild, so the system directories cannot be on it. The script
# needs only bash (for its shebang) and make before its preflight runs.
cp "$tmp/bin/make" "$tmp/nox/make"
ln -s "$(command -v bash)" "$tmp/nox/bash"

export PATH="$tmp/bin:$PATH"
export KERNOVA_CHECK_DIR="$tmp/out"
export FAKE_XCRESULT_FIXTURES="$FIX/xcresult"
export FAKE_ROOT="$ROOT"

count=0
failures=0
name=
fail() { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; failures=$((failures + 1)); }

# run <name> <expected exit> <command...> — stdout lands in $tmp/last.
run() {
    name="$1"
    local want="$2"
    shift 2
    count=$((count + 1))
    "$@" >"$tmp/last" 2>"$tmp/last.err"
    local got=$?
    if [ "$got" -ne "$want" ]; then
        fail "$name: exit $got, expected $want"
        sed 's/^/      /' "$tmp/last" "$tmp/last.err"
    fi
}
expect()       { grep -qE -- "$1" "$tmp/last" || fail "$name: output lacks /$1/"; }
reject()       { ! grep -qE -- "$1" "$tmp/last" || fail "$name: output has /$1/"; }
expect_count() { [ "$(grep -cE -- "$1" "$tmp/last")" -eq "$2" ] || fail "$name: expected $2 lines matching /$1/"; }
expect_last()  { [ "$(tail -n 1 "$tmp/last" | grep -cE -- "$1")" -eq 1 ] || fail "$name: last line is not /$1/: $(tail -n 1 "$tmp/last")"; }
expect_lines() { [ "$(grep -c . "$tmp/last")" -eq "$1" ] || fail "$name: expected $1 lines, got $(grep -c . "$tmp/last")"; }

check() { Tools/check.sh "$@"; }
with_log() { FAKE_MAKE_LOG="$tmp/logs/$1" FAKE_MAKE_STATUS="$2" Tools/check.sh "${@:3}"; }

# ---- check.sh: build -------------------------------------------------------

run "build green" 0 with_log build-ok.log 0 build
expect '^check: target=build suite=- duration=[0-9]+s log=.*/build\.log$'
expect_last '^check: verdict=green target=build suite=- log=.*/build\.log xcresult=-$'
expect_lines 2
[ -f "$tmp/out/build.verdict" ] || fail "$name: no verdict file written"
cmp -s "$tmp/out/build.verdict" "$tmp/last" || fail "$name: verdict file differs from stdout"

run "build failed" 2 with_log build-failed.log 2 build
expect '^errors:$'
expect_count "^  Kernova/Services/VMSession\.swift:42:9: error: cannot find 'foo' in scope$" 1
expect "^  KernovaKit/Sources/KernovaKit/Wire\.swift:7:1: error: missing return"
reject 'warning:'
reject "$ROOT"
expect_last '^check: verdict=build-failed target=build suite=- log=.*/build\.log xcresult=-$'

run "build-for-testing green" 0 with_log build-ok.log 0 build-for-testing
expect_last '^check: verdict=green target=build-for-testing '

# ---- check.sh: test --------------------------------------------------------

run "test failed" 1 with_log test-failed.log 65 test
expect '^result=Failed total=3948 passed=3945 failed=2 skipped=1 xfail=0$'
expect '^=== VMConfigurationTests/defaultsMatchTemplate\(\)$'
expect_count '^KernovaTests/VMConfigurationTests\.swift:42: Expectation failed: \(config\.cpuCount → 2\) == 4$' 1
expect '^=== VMConfigurationTests/rejectsZeroMemory\(\)$'
expect '^=== ClipboardTests/roundTrip\(\) \(passed on retry\)$'
reject '^xcresult-report:'
reject "$ROOT"
expect_last "^check: verdict=test-failed target=test suite=- total=3948 failed=2 flaky=1 log=.*/test\.log xcresult=$tmp/bundles/failed\.xcresult$"

run "test green" 0 with_log test-passed.log 0 test
expect '^result=Passed total=3948 passed=3948 failed=0 skipped=0 xfail=0$'
expect_last '^check: verdict=green target=test suite=- total=3948 failed=0 flaky=0 log=.* xcresult=.*/passed\.xcresult$'
expect_lines 3

run "suite matched nothing" 3 with_log test-none.log 0 test-suite KernovaTests/NoSuchSuite
expect '^check: target=test-suite suite=KernovaTests/NoSuchSuite '
expect_last '^check: verdict=no-tests-ran target=test-suite suite=KernovaTests/NoSuchSuite total=0 failed=0 flaky=0 '

run "test build failed" 2 with_log test-build-failed.log 65 test
expect '^errors:$'
expect "^  KernovaTests/VMConfigurationTests\.swift:18:22: error: value of type"
reject '^=== '
expect_last '^check: verdict=build-failed target=test '

run "test died before a bundle" 1 with_log test-died.log 70 test
expect '^tail:$'
expect '^  xcodebuild: error: Failed to write result bundle\.$'
expect_last '^check: verdict=test-failed target=test suite=- reason=no-result-bundle '

run "tests passed but make failed" 1 with_log test-passed.log 1 test
expect '^tail:$'
expect_last '^check: verdict=test-failed target=test suite=- total=3948 failed=0 flaky=0 reason=make-exit-1 '

run "test-without-building green" 0 with_log test-passed.log 0 test-without-building
expect_last '^check: verdict=green target=test-without-building '

# ---- check.sh: lint --------------------------------------------------------

run "lint green" 0 with_log lint-ok.log 0 lint
expect_last '^check: verdict=green target=lint suite=- log=.*/lint\.log xcresult=-$'

run "lint failed" 4 with_log lint-failed.log 2 lint
expect '^errors:$'
expect '^  In Tools/check\.sh line 12:$'
expect 'SC2086'
expect '^  Kernova/App/AppDelegate\.swift:12:1: error: \[Indentation\]'
expect '^  .*✗ docs/BUILD\.md:40 — 91 words'
reject 'make: \*\*\*'
expect_last '^check: verdict=lint-failed target=lint '

# ---- check.sh: --from-log and usage ----------------------------------------

run "from-log reports without running" 1 check --from-log "$tmp/logs/test-failed.log" test
expect '^check: target=test suite=- duration=- log='
expect_last '^check: verdict=test-failed target=test suite=- total=3948 failed=2 flaky=1 '

run "from-log build" 2 check --from-log "$tmp/logs/build-failed.log" build
expect_last '^check: verdict=build-failed '

run "from-log green" 0 check --from-log "$tmp/logs/build-ok.log" build
expect_last '^check: verdict=green '

run "unknown target" 5 check bogus
expect_last '^check: verdict=setup-error reason=usage target=bogus suite=-$'
run "test-suite without a suite" 5 check test-suite
expect_last '^check: verdict=setup-error reason=usage '
run "suite on a non-suite target" 5 check build KernovaTests/X
expect_last '^check: verdict=setup-error reason=usage '
run "missing log" 5 check --from-log "$tmp/logs/nope.log" test
expect_last '^check: verdict=setup-error reason=no-log '
run "xcodebuild missing" 5 env PATH="$tmp/nox" FAKE_MAKE_LOG="$tmp/logs/build-ok.log" Tools/check.sh build
expect_last '^check: verdict=setup-error reason=xcodebuild-missing '
run "help" 0 check --help
expect_lines 0

# ---- xcresult-report.sh ----------------------------------------------------

report() { Tools/xcresult-report.sh "$@"; }

run "report failed bundle" 1 report --path "$tmp/bundles/failed.xcresult"
expect '^result=Failed total=3948 passed=3945 failed=2 skipped=1 xfail=0$'
expect_count '^=== ' 3
expect_last "^xcresult-report: verdict=failed total=3948 failed=2 flaky=1 path=$tmp/bundles/failed\.xcresult$"

run "report passed bundle" 0 report --path "$tmp/bundles/passed.xcresult"
expect_last '^xcresult-report: verdict=passed total=3948 failed=0 flaky=0 '
expect_lines 2

run "report empty bundle" 3 report --path "$tmp/bundles/empty.xcresult"
expect_last '^xcresult-report: verdict=no-tests total=0 failed=0 flaky=0 '

run "report from log" 1 report --from-log "$tmp/logs/test-failed.log"
expect_last "path=$tmp/bundles/failed\.xcresult$"

run "flaky ids only" 0 report --path "$tmp/bundles/failed.xcresult" --flaky
expect_lines 1
expect '^ClipboardTests/roundTrip\(\)$'

run "flaky ids, none" 0 report --path "$tmp/bundles/passed.xcresult" --flaky
expect_lines 0

run "failure blocks only" 0 report --path "$tmp/bundles/failed.xcresult" --failures
expect_count '^=== ' 3
reject '^result='
reject '^xcresult-report:'

run "log names no bundle" 2 report --from-log "$tmp/logs/test-died.log"
expect_last '^xcresult-report: verdict=unreadable reason=no-bundle-in-log path=-$'

run "bundle missing on disk" 2 report --path "$tmp/bundles/nope.xcresult"
expect_last "^xcresult-report: verdict=unreadable reason=no-bundle path=$tmp/bundles/nope\.xcresult$"

run "tooling mode on a missing bundle" 2 report --path "$tmp/bundles/nope.xcresult" --flaky
expect_lines 0

run "unknown flag" 2 report --bogus

# ---- summary ---------------------------------------------------------------

if [ "$failures" -gt 0 ]; then
    printf '\n%s of %s tool fixture checks failed\n' "$failures" "$count" >&2
    exit 1
fi
pass "tools: $count fixture checks (Tools/tests/run.sh)"
