#!/usr/bin/env bash
# Fixture tests for `Tools/ghosts.sh --fix` on a worktree moved by hand: it is
# reported with its repair, and nothing prunes its record, trashes it, or
# evicts its arena or editor cache, while a directory Xcode recreated after a
# removal still goes. Runs a copy of the scripts inside a fixture clone, with
# HOME in the fixture and fakes for every tool that reaches past it
# (lsregister, defaults, pgrep, mdfind, trash, launchctl). Local git only.

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
cp "$ROOT/Tools/ghosts.sh" "$ROOT/Tools/arena-label.sh" "$ROOT/Tools/derived-data-path.sh" "$clone/Tools/"
cp "$ROOT/Tools/lib/build-arenas.sh" "$ROOT/Tools/lib/arena-records.sh" "$ROOT/Tools/lib/output.sh" \
    "$ROOT/Tools/lib/worktrees.sh" "$ROOT/Tools/lib/holders.sh" "$ROOT/Tools/lib/xcodebuild-flags.sh" \
    "$clone/Tools/lib/"

# --fix evicts in this root, so the suite stops unless it is in the fixture.
dd_root=$("$clone/Tools/derived-data-path.sh" --root)
case "$dd_root" in
    "$base"/*) ;;
    *)
        echo "ghosts fixtures: the scripts' DerivedData root '$dd_root' is outside $base" >&2
        exit 1
        ;;
esac

wts="$clone/.claude/worktrees"
git -C "$clone" worktree add -q --detach "$wts/before"
echo 'uncommitted' >"$wts/before/edit.txt"
mv "$wts/before" "$wts/after"
record_dir=$(sed -n 's/^gitdir: //p' "$wts/after/.git")
arena=$("$clone/Tools/derived-data-path.sh" "$wts/after/Kernova.xcodeproj")
mkdir -p "$arena"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>WorkspacePath</key><string>%s</string></dict></plist>\n' \
    "$wts/after/Kernova.xcodeproj" >"$arena/info.plist"
cache="$HOME/Library/Caches/xcode-build-server/${wts//\//-}-after"
mkdir -p "$cache"

# Removed, then recreated by Xcode writing its user state there.
git -C "$clone" worktree add -q --detach "$wts/gone"
git -C "$clone" worktree remove "$wts/gone"
mkdir -p "$wts/gone/Kernova.xcodeproj/project.xcworkspace/xcuserdata"

out=$("$clone/Tools/ghosts.sh" --fix </dev/null 2>&1)

check "moved worktree: its record is not pruned" "$(present "$record_dir")" present
check "moved worktree: still a checkout" "$(git -C "$wts/after" rev-parse --is-inside-work-tree 2>/dev/null)" true
check "moved worktree: not trashed" "$(present "$wts/after/edit.txt")" present
check "moved worktree: its arena" "$(present "$arena")" present
check "moved worktree: its xcode-build-server cache" "$(present "$cache")" present
check "moved worktree: reported with its repair" \
    "$(grep -c "git worktree repair '$wts/after'" <<<"$out")" 1
check "recreated directory: trashed" "$(present "$wts/gone")$(present "$HOME/.Trash/gone")" gonepresent

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s ghosts: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
