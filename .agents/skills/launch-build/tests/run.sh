#!/usr/bin/env bash
# Fixture tests for the launch-build skill: drives launch-build.sh through
# every verdict against fake app bundles, with fakes of `osascript` and `open`
# first on PATH that answer from a fake Launch Services registry. The fixture
# bundles carry a bundle identifier no real app has, so even a fake gone
# missing could never reach a real Kernova. Runs in seconds; run it after
# editing the skill.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$ROOT/.agents/skills/launch-build/launch-build.sh"
FIXTURE_ID=app.kernova.launch-build-fixture

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

# Left unresolved — on macOS mktemp answers under /var, a symlink to
# /private/var — so every path the script is handed needs canonicalizing, and
# the verdicts name the resolved spelling.
tmp="$(mktemp -d)"
rtmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export FAKE_LS="$tmp/ls" FAKE_STATE="$tmp/state"
mkdir -p "$tmp/bin"

cat >"$tmp/bin/osascript" <<'FAKE'
#!/bin/bash
# launch-build's Launch Services query, answered from $FAKE_LS: one file per
# registered copy, named for its pid and holding "<bundle-id>\t<executable>".
# $FAKE_STATE/ae/<pid> is how that copy takes the quit Apple event: quit (the
# default), stuck (sent, and it stays up), no (terminate answers NO), error
# (osascript fails).
while [ $# -gt 0 ]; do case "$1" in -l | -e) shift 2 ;; *) break ;; esac; done
printf 'osascript %s\n' "$*" >>"$FAKE_STATE/calls"
case "$1" in
    list)
        if [ -e "$FAKE_STATE/list-fails" ]; then echo 'execution error: fixture (-600)' >&2; exit 1; fi
        for f in "$FAKE_LS"/*; do
            [ -f "$f" ] || continue
            IFS=$'\t' read -r id exe <"$f"
            if [ "$id" = "$2" ]; then printf '%s\t%s\n' "${f##*/}" "$exe"; fi
        done
        ;;
    quit)
        f="$FAKE_LS/$2"
        id=
        [ -f "$f" ] && IFS=$'\t' read -r id _ <"$f"
        if [ "$id" != "$3" ]; then echo gone; exit 0; fi
        case "$(cat "$FAKE_STATE/ae/$2" 2>/dev/null || echo quit)" in
            quit) rm -f "$f"; echo sent ;;
            stuck) echo sent ;;
            no) echo refused ;;
            error) echo 'execution error: fixture refusal (-1743)' >&2; exit 1 ;;
        esac
        ;;
    *) echo "fake osascript: unexpected $*" >&2; exit 1 ;;
esac
exit 0
FAKE

cat >"$tmp/bin/open" <<'FAKE'
#!/bin/bash
# `open <bundle>` as Launch Services routes it: a registered copy of the same
# bundle identifier takes it as a reopen, and only otherwise does <bundle>
# launch. $FAKE_STATE/open overrides that: fail, crash (nothing registers), or
# hijack:<executable> (that copy comes up instead).
printf 'open %s\n' "$*" >>"$FAKE_STATE/calls"
case "$1" in -*) echo "fake open: unexpected option $1" >&2; exit 64 ;; esac
bundle="$1"
id="$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist")" || exit 1
register() {
    pid="$(cat "$FAKE_STATE/next-pid")"
    echo $((pid + 1)) >"$FAKE_STATE/next-pid"
    printf '%s\t%s\n' "$id" "$1" >"$FAKE_LS/$pid"
}
mode="$(cat "$FAKE_STATE/open" 2>/dev/null || echo launch)"
case "$mode" in
    fail) echo 'fake open: The application cannot be opened.' >&2; exit 1 ;;
    crash) exit 0 ;;
    hijack:*) register "${mode#hijack:}"; exit 0 ;;
esac
for f in "$FAKE_LS"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r other _ <"$f"
    if [ "$other" = "$id" ]; then exit 0; fi
done
register "$bundle/Contents/MacOS/Kernova"
FAKE

# A copy's bundled `kernova`. The file beside it says what `quit` does: self
# (quits this copy), other:<pid> (the socket reached that copy instead), noop
# (reaches nothing), exit:<n>, or hang (a save pass that outlasts the wait).
cat >"$tmp/tool" <<'FAKE'
#!/bin/bash
here="$(cd "$(dirname "$0")" && pwd -P)"
bundle="${here%/Contents/Helpers}"
printf 'tool %s %s\n' "$bundle" "$*" >>"$FAKE_STATE/calls"
behaviour="$(cat "$here/behaviour")"
case "$behaviour" in
    self)
        for f in "$FAKE_LS"/*; do
            [ -f "$f" ] || continue
            IFS=$'\t' read -r _ exe <"$f"
            dir="$(cd "$(dirname "$exe")" 2>/dev/null && pwd -P)"
            if [ "$dir/$(basename "$exe")" = "$bundle/Contents/MacOS/Kernova" ]; then rm -f "$f"; fi
        done
        ;;
    other:*) rm -f "$FAKE_LS/${behaviour#other:}" ;;
    noop) ;;
    exit:*) exit "${behaviour#exit:}" ;;
    hang)
        echo "$$" >"$FAKE_STATE/tool-pid"
        while :; do sleep 0.05; done
        ;;
esac
exit 0
FAKE
chmod +x "$tmp/bin"/* "$tmp/tool"
export PATH="$tmp/bin:$PATH"

# make_copy <bundle> [no-tool | no-id]
make_copy() {
    mkdir -p "$1/Contents/MacOS"
    if [ "${2:-}" = no-id ]; then
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Kernova</string></dict></plist>\n' >"$1/Contents/Info.plist"
    else
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>Kernova</string></dict></plist>\n' "$FIXTURE_ID" >"$1/Contents/Info.plist"
    fi
    printf '#!/bin/sh\nexit 0\n' >"$1/Contents/MacOS/Kernova"
    chmod +x "$1/Contents/MacOS/Kernova"
    if [ "${2:-}" != no-tool ]; then
        mkdir -p "$1/Contents/Helpers"
        cp "$tmp/tool" "$1/Contents/Helpers/kernova"
    fi
}

BUILD="$tmp/Derived Data/Build/Products/Debug/Kernova.app"
INSTALLED="$tmp/Applications/Kernova.app"
COPY="$tmp/Downloads/Kernova Copy.app"
TOOLLESS="$tmp/Release/Kernova.app"
for b in "$BUILD" "$INSTALLED" "$COPY"; do make_copy "$b"; done
make_copy "$TOOLLESS" no-tool
make_copy "$tmp/NoID/Kernova.app" no-id
mkdir -p "$tmp/plain" && printf '#!/bin/sh\n' >"$tmp/plain/kernova" && chmod +x "$tmp/plain/kernova"

ARG="$BUILD/Contents/MacOS/Kernova"
exe_of() { printf '%s/Contents/MacOS/Kernova' "$rtmp${1#"$tmp"}"; }
B="$(exe_of "$BUILD")"

# reset — an empty registry, every tool quitting its own copy, and open routing
# as Launch Services does.
reset() {
    rm -rf "$FAKE_LS" "$FAKE_STATE"
    mkdir -p "$FAKE_LS" "$FAKE_STATE/ae"
    echo 500 >"$FAKE_STATE/next-pid"
    : >"$FAKE_STATE/calls"
    for b in "$BUILD" "$INSTALLED" "$COPY"; do behaviour "$b" self; done
}
behaviour() { printf '%s\n' "$2" >"$1/Contents/Helpers/behaviour"; }
register() { printf '%s\t%s\n' "$FIXTURE_ID" "$2/Contents/MacOS/Kernova" >"$FAKE_LS/$1"; }

# run <name> <expected-exit> <expected-verdict-line> [args...]
run() {
    name="$1"
    local want_exit="$2" want="$3" out code
    shift 3
    out="$("$SCRIPT" "$@" 2>"$tmp/err")"; code=$?
    [ "$code" -eq "$want_exit" ] || fail "$name: exit $code, wanted $want_exit"
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "$name: stdout is not exactly one line: $out"
    if [ "$out" = "$want" ]; then pass; else fail "$name: got '$out', wanted '$want'"; fi
}
called()     { if grep -qxF -- "$1" "$FAKE_STATE/calls"; then pass; else fail "$name: no call '$1'"; fi; }
not_called() { if ! grep -qF -- "$1" "$FAKE_STATE/calls"; then pass; else fail "$name: unexpected call matching '$1'"; fi; }
calls()      { if [ "$(grep -cxF -- "$1" "$FAKE_STATE/calls")" -eq "$2" ]; then pass; else fail "$name: '$1' called $(grep -cxF -- "$1" "$FAKE_STATE/calls") times, wanted $2"; fi; }
registered() { # <pid...> — exactly these copies are registered
    local got="" f
    for f in "$FAKE_LS"/*; do [ -f "$f" ] && got="$got ${f##*/}"; done
    if [ "$got" = " $*" ]; then pass; else fail "$name: registered '${got# }', wanted '$*'"; fi
}
stderr_has() { if grep -qF -- "$1" "$tmp/err"; then pass; else fail "$name: stderr lacks '$1': $(cat "$tmp/err")"; fi; }

# ---- launching ---------------------------------------------------------------

reset
run "nothing running" 0 "launch-build: verdict=running pid=500 binary=$B" "$ARG"
called "open $rtmp/Derived Data/Build/Products/Debug/Kernova.app"
not_called "tool "
not_called "osascript quit"
registered 500

reset
run "the binary= token as the verdict prints it" 0 "launch-build: verdict=running pid=500 binary=$B" --timeout 09 "binary=$ARG"

# ---- quitting through each copy's own tool ----------------------------------

reset
register 101 "$INSTALLED"
run "the installed copy" 0 "launch-build: verdict=running pid=500 binary=$B" "$ARG"
called "tool $rtmp/Applications/Kernova.app quit"
not_called "osascript quit"
registered 500

# The build's own path already running is quit too: its process is the image
# that path held when it launched.
reset
register 101 "$BUILD"
run "the build's own path, launched earlier" 0 "launch-build: verdict=running pid=500 binary=$B" "$ARG"
called "tool $rtmp/Derived Data/Build/Products/Debug/Kernova.app quit"
registered 500

reset
register 101 "$INSTALLED"
register 102 "$COPY"
run "several copies" 0 "launch-build: verdict=running pid=500 binary=$B" "$ARG"
called "tool $rtmp/Applications/Kernova.app quit"
called "tool $rtmp/Downloads/Kernova Copy.app quit"
not_called "osascript quit"
registered 500

# A tool's socket reaches whichever copy holds it: here the installed copy's
# tool quits the other one, so the installed copy is sent the Apple event, and
# the other copy's tool is never needed.
reset
register 101 "$INSTALLED"
register 102 "$COPY"
behaviour "$INSTALLED" other:102
run "a tool whose socket reaches another copy" 0 "launch-build: verdict=running pid=500 binary=$B" "$ARG"
calls "tool $rtmp/Applications/Kernova.app quit" 1
not_called "tool $rtmp/Downloads/Kernova Copy.app"
called "osascript quit 101 $FIXTURE_ID"
registered 500

# ---- the Apple-event fallback -----------------------------------------------

reset
register 101 "$TOOLLESS"
run "a copy with no tool" 0 "launch-build: verdict=running pid=500 binary=$B" "$ARG"
called "osascript quit 101 $FIXTURE_ID"
registered 500

for code in 8 9 1; do
    reset
    register 101 "$INSTALLED"
    behaviour "$INSTALLED" "exit:$code"
    run "a tool that exits $code" 0 "launch-build: verdict=running pid=500 binary=$B" "$ARG"
    calls "tool $rtmp/Applications/Kernova.app quit" 1
    called "osascript quit 101 $FIXTURE_ID"
    registered 500
done

reset
register 101 "$INSTALLED"
behaviour "$INSTALLED" noop
run "a tool that reaches nothing" 0 "launch-build: verdict=running pid=500 binary=$B" "$ARG"
calls "tool $rtmp/Applications/Kernova.app quit" 1
called "osascript quit 101 $FIXTURE_ID"

for how in error no; do
    reset
    register 101 "$TOOLLESS"
    echo "$how" >"$FAKE_STATE/ae/101"
    run "an Apple-event quit that cannot be sent ($how)" 4 "launch-build: verdict=quit-refused pid=101 running=$(exe_of "$TOOLLESS")" "$ARG"
    not_called "open "
    registered 101
    [ "$how" = no ] || stderr_has "execution error: fixture refusal (-1743)"
done

# ---- waits that run out -----------------------------------------------------

# Nothing is signalled: the copy is left to finish its save pass, and only the
# waiting tool is stopped.
reset
register 101 "$INSTALLED"
behaviour "$INSTALLED" hang
run "a save pass that outlasts the wait" 3 "launch-build: verdict=quit-timeout pid=101 running=$(exe_of "$INSTALLED")" --timeout 1 "$ARG"
not_called "open "
registered 101
if [ ! -f "$FAKE_STATE/tool-pid" ] || ! kill -0 "$(cat "$FAKE_STATE/tool-pid")" 2>/dev/null; then pass; else fail "$name: the waiting tool was left running"; fi

reset
register 101 "$TOOLLESS"
echo stuck >"$FAKE_STATE/ae/101"
run "an Apple-event quit the copy never acts on" 3 "launch-build: verdict=quit-timeout pid=101 running=$(exe_of "$TOOLLESS")" --timeout 1 "$ARG"
not_called "open "

# ---- after the open ---------------------------------------------------------

reset
echo fail >"$FAKE_STATE/open"
run "open fails" 2 "launch-build: verdict=not-running reason=open-failed" "$ARG"
stderr_has "fake open: The application cannot be opened."

reset
echo crash >"$FAKE_STATE/open"
run "the build never registers" 2 "launch-build: verdict=not-running reason=not-registered" --timeout 1 "$ARG"

reset
echo "hijack:$INSTALLED/Contents/MacOS/Kernova" >"$FAKE_STATE/open"
run "another copy comes up in the build's place" 1 "launch-build: verdict=mismatch pid=500 running=$(exe_of "$INSTALLED")" "$ARG"

# ---- setup ------------------------------------------------------------------

reset
run "no argument" 5 "launch-build: verdict=setup-error reason=usage argument=-"
run "unknown option" 5 "launch-build: verdict=setup-error reason=usage argument=--bogus" --bogus "$ARG"
run "two binaries" 5 "launch-build: verdict=setup-error reason=usage argument=$ARG" "$ARG" "$ARG"
run "a timeout that is not a count" 5 "launch-build: verdict=setup-error reason=usage argument=--timeout soon" --timeout soon "$ARG"
run "a zero timeout" 5 "launch-build: verdict=setup-error reason=usage argument=--timeout 0" --timeout 00 "$ARG"
run "a missing build" 5 "launch-build: verdict=setup-error reason=no-build path=$tmp/nope/Kernova" "$tmp/nope/Kernova"
run "an executable outside an app" 5 "launch-build: verdict=setup-error reason=not-an-app path=$rtmp/plain/kernova" "$tmp/plain/kernova"
run "a bundle with no identifier" 5 "launch-build: verdict=setup-error reason=no-bundle-identifier path=$rtmp/NoID/Kernova.app" "$tmp/NoID/Kernova.app/Contents/MacOS/Kernova"
not_called "osascript"

reset
touch "$FAKE_STATE/list-fails"
run "Launch Services cannot be asked" 5 "launch-build: verdict=setup-error reason=query-failed" "$ARG"
not_called "open "

name="help"
out="$("$SCRIPT" --help 2>"$tmp/err")"; code=$?
if [ "$code" -eq 0 ] && [ -z "$out" ]; then pass; else fail "$name: exit $code, stdout '$out'"; fi
stderr_has "Verdict tokens and exit codes:"

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s launch-build: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
