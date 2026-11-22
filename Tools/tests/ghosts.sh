#!/usr/bin/env bash
# Fixture tests for `Tools/ghosts.sh --fix` on checkouts under
# .claude/worktrees/ that git does not register: a worktree moved by hand is
# registered again, keeping its builds and editor cache, before stale records
# are pruned; one whose record is gone and a copy of a live worktree keep their
# files and change nothing; a directory Xcode recreated after a removal goes to
# the Trash. Kernova arenas in Xcode's DerivedData folder are reported with the
# command that removes them, and left. Runs a copy of the scripts inside a
# fixture clone, with HOME in the fixture and fakes for every tool that reaches
# past it (lsregister, defaults, pgrep, mdfind, trash, launchctl). Local git
# only.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else fail "$1: got '$2', wanted '$3'"; fi
}
present() { if [ -e "$1" ]; then printf present; else printf gone; fi; }

base="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$base"' EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$base"

fakes="$base/fakes"
mkdir -p "$fakes" "$HOME/.Trash"
printf '#!/bin/bash\nexit 0\n' >"$fakes/lsregister"
for tool in defaults pgrep mdfind launchctl; do
    printf '#!/bin/bash\nexit 1\n' >"$fakes/$tool"
done
cat >"$fakes/trash" <<EOF
#!/bin/bash
mv "\$1" '$HOME/.Trash/'
EOF
chmod +x "$fakes"/*
export PATH="$fakes:$PATH"

clone="$base/clone"
git init -q -b main "$clone"
mkdir -p "$clone/Kernova.xcodeproj"
touch "$clone/Kernova.xcodeproj/project.pbxproj"
git -C "$clone" add Kernova.xcodeproj && git -C "$clone" commit -q -m init
mkdir -p "$clone/Tools/lib"
cp "$ROOT/Tools/ghosts.sh" "$clone/Tools/"
cp "$ROOT/Tools/lib/build-arenas.sh" "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/worktrees.sh" \
    "$ROOT/Tools/lib/holders.sh" "$clone/Tools/lib/"

# The Xcode app's arenas, under HOME, which is in the fixture.
xcode_arena="$HOME/Library/Developer/Xcode/DerivedData/Kernova-$(printf 'a%.0s' {1..28})"
mkdir -p "$xcode_arena/Build/Products/Debug/Kernova.app"

wts="$clone/.claude/worktrees"
common="$clone/.git"
add() { git -C "$clone" worktree add -q --detach "$wts/$1" && echo 'uncommitted' >"$wts/$1/edit.txt"; }

# Moved by hand, and its record pruned since.
add lost
mv "$wts/lost" "$wts/lost moved"
git -C "$clone" worktree prune

# Moved by hand: its record names the old path.
add before
mv "$wts/before" "$wts/after"
arena="$wts/after/DerivedData/Make"
mkdir -p "$arena/Build/Products/Debug/Kernova.app"
cache="$HOME/Library/Caches/xcode-build-server/${wts//\//-}-after"
mkdir -p "$cache"

# A copy of a live worktree, whose .git file names the original's record.
add original
cp -R "$wts/original" "$wts/original copy"
echo 'the copy' >"$wts/original copy/edit.txt"

# A stale record, and a removed worktree's directory Xcode recreated.
add stale
rm -rf "$wts/stale"
git -C "$clone" worktree add -q --detach "$wts/gone"
git -C "$clone" worktree remove "$wts/gone"
mkdir -p "$wts/gone/Kernova.xcodeproj/project.xcworkspace/xcuserdata"

out=$("$clone/Tools/ghosts.sh" --fix </dev/null 2>&1)

check "moved: its files" "$(cat "$wts/after/edit.txt" 2>/dev/null)" uncommitted
check "moved: git works in it" "$(git -C "$wts/after" rev-parse --show-toplevel 2>/dev/null)" "$wts/after"
check "moved: registered again" "$(git -C "$clone" worktree list --porcelain | grep -cxF "worktree $wts/after")" 1
check "moved: its builds" "$(present "$arena")" present
check "moved: its xcode-build-server cache" "$(present "$cache")" present
check "stale record: pruned" "$(present "$common/worktrees/stale")" gone
check "record gone: its files" "$(cat "$wts/lost moved/edit.txt" 2>/dev/null)" uncommitted
check "record gone: reported" "$(grep -c "Checkout git cannot use: .*lost moved" <<<"$out")" 1
check "copy: its files" "$(cat "$wts/original copy/edit.txt" 2>/dev/null)" 'the copy'
check "copy: the original's record still names the original" \
    "$(cat "$common/worktrees/original/gitdir")" "$wts/original/.git"
check "copy: reported" "$(grep -c "Copy of the worktree at .*original: .*original copy" <<<"$out")" 1
check "recreated directory: trashed" "$(present "$wts/gone")$(present "$HOME/.Trash/gone")" gonepresent
check "Xcode's arenas: reported with the command removing them" \
    "$(grep -c '^ *rm -rf ~/Library/Developer/Xcode/DerivedData/Kernova-\*$' <<<"$out")" 1
check "Xcode's arenas: left" "$(present "$xcode_arena")" present

"$clone/Tools/ghosts.sh" --fix </dev/null >/dev/null 2>&1
check "a second --fix: exit status" "$?" 0
check "a second --fix: the record-gone checkout's files" "$(cat "$wts/lost moved/edit.txt" 2>/dev/null)" uncommitted

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s ghosts: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
