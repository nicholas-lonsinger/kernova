#!/usr/bin/env bash
# Keeps a scheduled scan's tracking issue: the one open issue labelled <label>
# whose title starts with <prefix>, if any. Each scan writes a complete
# snapshot, never merged with an earlier one, and a closed tracker is history:
#
#   clean, a tracker open      comment that the scan ran clean, and close it
#   clean, none open           nothing
#   findings, a tracker open   replace its title and body
#   findings, none open        open a new one, typed Task, and link it both
#                              ways with the newest closed tracker, if any
#
# Usage:
#   Tools/tracking-issue.sh <label> <prefix> <workflow> clean
#   Tools/tracking-issue.sh <label> <prefix> <workflow> findings <title> <summary> <body file>
#
# <workflow> is the workflow file that runs the scan, which the body links;
# <summary> opens the body, in bold, ahead of <body file>. gh reads the
# repository from GH_REPO and its token from GH_TOKEN.

set -euo pipefail

usage() {
    echo 'usage: Tools/tracking-issue.sh <label> <prefix> <workflow> clean | findings <title> <summary> <body file>' >&2
    exit 2
}

[ $# -ge 4 ] || usage
label=$1 prefix=$2 workflow=$3 verdict=$4
case "$verdict" in
    clean) [ $# -eq 4 ] || usage ;;
    findings) [ $# -eq 7 ] || usage ;;
    *)
        echo "tracking-issue: the verdict is '$verdict', not clean or findings" >&2
        exit 1
        ;;
esac
: "${GH_REPO:?tracking-issue: GH_REPO names no repository}"
now=$(date -u +%Y-%m-%dT%H:%MZ)

# newest_tracker <open|closed> — the number of the newest tracker in that state.
newest_tracker() {
    gh api --method GET --paginate "repos/$GH_REPO/issues" -f state="$1" -f labels="$label" -f per_page=100 |
        jq -rs --arg prefix "$prefix" 'map(.[]) | map(select(.pull_request == null and (.title | startswith($prefix))))
            | sort_by(.number) | last | .number // empty'
}

open_issue=$(newest_tracker open)

if [ "$verdict" = clean ]; then
    if [ -n "$open_issue" ]; then
        gh issue comment "$open_issue" \
            --body "Scan ran clean on $now — closing. A new issue is opened automatically if findings reappear."
        gh issue close "$open_issue"
    fi
    exit 0
fi

title=$5 summary=$6 findings=$7
body=$(mktemp)
trap 'rm -f "$body"' EXIT
{
    printf 'Last scan: %s — **%s**\n\n' "$now" "$summary"
    printf 'Auto-managed by [`%s`](%s/%s/blob/main/%s) on `main`. ' "$workflow" "${GITHUB_SERVER_URL:-https://github.com}" "$GH_REPO" "$workflow"
    printf "Each scan fully replaces the lists below — findings are never combined across runs. The next clean scan closes this issue if a PR hasn't already; a brand-new issue is opened if findings reappear later.\n\n"
    cat "$findings"
} >"$body"

if [ -n "$open_issue" ]; then
    gh issue edit "$open_issue" --title "$title" --body-file "$body"
    exit 0
fi

previous=$(newest_tracker closed)
if [ -n "$previous" ]; then
    { printf 'Supersedes #%s — these findings replace that issue'"'"'s list; they are not combined with it.\n\n' "$previous"; cat "$body"; } >"$body.linked"
    mv "$body.linked" "$body"
fi

url=$(gh api "repos/$GH_REPO/issues" -f title="$title" -F body=@"$body" -f "labels[]=$label" -f type=Task | jq -r .html_url)
echo "Opened $url"

if [ -n "$previous" ]; then
    gh issue comment "$previous" \
        --body "Superseded by #${url##*/} — newer scan with current findings. This issue's list is historical and is not combined with the new one."
fi
