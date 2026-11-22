#!/usr/bin/env bash
# Fixture tests for Tools/tracking-issue.sh: what it does with each verdict
# when a tracker is open, when only a closed one exists and when none does;
# which issue it takes as the tracker; and that a label the repository lacks,
# a verdict it does not know, or a listing that fails, changes nothing. gh is
# a stub that serves the fixture's label and issue listings and logs every
# other call.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
check() { [ "$2" = "$3" ] || fail "$1: got '$2', wanted '$3'"; }
has() { [[ $2 == *"$3"* ]] || fail "$1: '$2' does not contain '$3'"; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

stubs="$tmp/stubs"
mkdir -p "$stubs"
# gh answers for the label while $FIXTURE/label exists, and serves the
# label's issues in a state from $FIXTURE/<state>.json while that exists; it
# logs every other call. A created issue is #900, and the body of a created
# or edited one is kept in $FIXTURE/body.
cat >"$stubs/gh" <<'EOF'
#!/bin/bash
case "$*" in
    'api repos/o/r/labels/Outdated%20Pins')
        [ -f "$FIXTURE/label" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
        echo '{"name": "Outdated Pins"}'
        exit 0
        ;;
    'api --method GET --paginate repos/o/r/issues -f state='*' -f labels=Outdated Pins -f per_page=100')
        state=${7#state=}
        [ -f "$FIXTURE/$state.json" ] || exit 1
        cat "$FIXTURE/$state.json"
        exit 0
        ;;
esac
printf '%s\n' "$*" >>"$FIXTURE/gh.log"
for arg; do
    case "$arg" in body=@*) cp "${arg#body=@}" "$FIXTURE/body" ;; esac
done
case "$*" in
    'api repos/o/r/issues '*) echo '{"number": 900, "html_url": "https://github.com/o/r/issues/900"}' ;;
    'issue edit '*) cp "${@: -1}" "$FIXTURE/body" ;;
esac
EOF
chmod +x "$stubs/gh"
export FIXTURE="$tmp" GH_REPO=o/r PATH="$stubs:$PATH"

printf '### Findings\n\n- one\n' >"$tmp/findings.md"

# listing <state> <page>... — the issues gh lists in that state, one JSON array per page.
listing() { printf '%s' "${@:2}" >"$tmp/$1.json"; }
# issue <number> <title> [pr] — an issue, or with `pr` a pull request, as the REST API lists it.
issue() {
    local pull_request=', "pull_request": {}'
    printf '{"number": %s, "title": "%s"%s}' "$1" "$2" "${3:+$pull_request}"
}

reset() {
    rm -f "$tmp/gh.log" "$tmp/body"
    touch "$tmp/label"
    listing open '[]'
    listing closed '[]'
}
calls() { cat "$tmp/gh.log" 2>/dev/null; }
tracker() { bash "$ROOT/Tools/tracking-issue.sh" 'Outdated Pins' 'Outdated pins' .github/workflows/outdated-pins.yml "$@" >/dev/null 2>&1; }
findings() { tracker findings 'Outdated pins: 2 behind' '2 behind' "$tmp/findings.md"; }

# The tracker is the newest issue in the state whose title starts with the
# prefix, on any page; a pull request and another title are not one.
open_pages=("[$(issue 50 'Outdated pins: 1 behind'), $(issue 70 'Outdated pins: 3 behind' pr), $(issue 60 'Other: Outdated pins')]"
    "[$(issue 55 'Outdated pins: 2 behind'), $(issue 40 'Outdated pins: 4 behind')]")

reset
listing open "${open_pages[@]}"
tracker clean
check 'clean, open: exit status' "$?" 0
check 'clean, open: calls' "$(calls | sed 's/ on [0-9T:-]*Z / on <date> /')" \
    $'issue comment 55 --body Scan ran clean on <date> — closing. A new issue is opened automatically if findings reappear.\nissue close 55'

reset
listing closed "[$(issue 30 'Outdated pins: 1 behind')]"
tracker clean
check 'clean, none open: exit status' "$?" 0
check 'clean, none open: calls' "$(calls)" ''

reset
listing open "${open_pages[@]}"
listing closed "[$(issue 30 'Outdated pins: 1 behind')]"
findings
check 'findings, open: exit status' "$?" 0
check 'findings, open: calls' "$(calls | sed 's/--body-file .*/--body-file <file>/')" \
    'issue edit 55 --title Outdated pins: 2 behind --body-file <file>'
has 'findings, open: summary' "$(head -1 "$tmp/body")" ' — **2 behind**'
check 'findings, open: findings last' "$(tail -3 "$tmp/body")" "$(cat "$tmp/findings.md")"

reset
listing closed "[$(issue 30 'Outdated pins: 1 behind'), $(issue 35 'Outdated pins: 5 behind' pr), $(issue 20 'Outdated pins: 9 behind')]"
findings
check 'findings, closed one: exit status' "$?" 0
check 'findings, closed one: calls' "$(calls | sed 's/body=@[^ ]*/body=@<file>/')" \
    $'api repos/o/r/issues -f title=Outdated pins: 2 behind -F body=@<file> -f labels[]=Outdated Pins -f type=Task\nissue comment 30 --body Superseded by #900 — newer scan with current findings. This issue\'s list is historical and is not combined with the new one.'
check 'findings, closed one: links it first' "$(head -1 "$tmp/body")" \
    "Supersedes #30 — these findings replace that issue's list; they are not combined with it."
check 'findings, closed one: findings last' "$(tail -3 "$tmp/body")" "$(cat "$tmp/findings.md")"

reset
findings
check 'findings, none: exit status' "$?" 0
check 'findings, none: calls' "$(calls | sed 's/body=@[^ ]*/body=@<file>/')" \
    'api repos/o/r/issues -f title=Outdated pins: 2 behind -F body=@<file> -f labels[]=Outdated Pins -f type=Task'
has 'findings, none: opens with the summary' "$(head -1 "$tmp/body")" 'Last scan: '

# Nothing changes under a label the repository lacks, on a verdict it does not
# know, or when a listing fails.
reset
rm "$tmp/label"
listing open "${open_pages[@]}"
! tracker clean || fail 'no label, clean: exited 0'
check 'no label, clean: calls' "$(calls)" ''
! findings || fail 'no label, findings: exited 0'
check 'no label, findings: calls' "$(calls)" ''

reset
listing open "${open_pages[@]}"
! tracker unknown || fail 'unknown verdict: exited 0'
check 'unknown verdict: calls' "$(calls)" ''

reset
rm "$tmp/open.json"
! findings || fail 'open listing fails: exited 0'
check 'open listing fails: calls' "$(calls)" ''

reset
rm "$tmp/closed.json"
! findings || fail 'closed listing fails: exited 0'
check 'closed listing fails: calls' "$(calls)" ''

if [ "$FAIL" -gt 0 ]; then
    printf '%d tracking-issue fixture(s) failed\n' "$FAIL"
    exit 1
fi
printf 'tracking-issue fixtures: all passed\n'
