#!/usr/bin/env bash
# Fixture tests for Tools/test-linux.sh and Tools/lib/linux-tests.sh: the tar a
# run feeds the container holds exactly the tree's Linux test inputs, untracked
# ones included and ignored ones not; a failed run exits 1 and a run that
# cannot happen exits 3; the image is named by its recipe alone and built from
# the tree's recipe, not the disk's; the store keeps the three images built
# last, so two recipes in turn delete neither and a fourth deletes the oldest,
# an image with no build time counts as the oldest, and no base is deleted; a stopped service is started, and nothing runs when
# the service will not start, container is absent, the Mac has no hypervisor,
# or the image cannot be built; an image gone when the run starts exits 3.
# Runs in a fixture clone with stub container and sysctl.

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
mkdir -p "$clone/Tools/lib" "$clone/KernovaKit/Sources" "$clone/KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk" \
    "$clone/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" "$clone/App"
cp "$ROOT/Tools/test-linux.sh" "$clone/Tools/"
cp "$ROOT/Tools/lib/linux-tests.sh" "$ROOT/Tools/lib/package-pins.sh" "$clone/Tools/lib/"
echo 'FROM ${BASE}' >"$clone/Tools/linux-tests.Containerfile"
echo 9.8.7 >"$clone/.swift-version"
echo pins >"$clone/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
echo script >"$clone/KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk/agent-disk.sh"
echo readme >"$clone/KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk/README.txt"
echo manifest >"$clone/KernovaKit/Package.swift"
echo source >"$clone/KernovaKit/Sources/A.swift"
echo app >"$clone/App/Main.swift"
printf '.build/\n' >"$clone/.gitignore"
git -C "$clone" add -A && git -C "$clone" commit -q -m init
test_linux="$clone/Tools/test-linux.sh"

# Every input the commit holds, as a tar of it lists them.
inputs='.swift-version
Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk/agent-disk.sh
KernovaKit/Package.swift
KernovaKit/Sources/A.swift
Tools/lib/linux-tests.sh
Tools/lib/package-pins.sh
Tools/linux-tests.Containerfile
Tools/test-linux.sh'

# The container stub logs each call and keeps an image store in
# $FIXTURE/store.json, shaped as `container image list --format json` prints
# it. `build` adds its tag, built a second after the build before it, and
# pulls its base when the store lacks it; `run` saves its stdin and exits
# $FIXTURE/run.status, or, when $FIXTURE/run.vanish exists, finds its image
# deleted and fails; `system status`, `system start` and `build` exit their
# files' statuses.
stubs="$tmp/stubs"
mkdir -p "$stubs"
cat >"$stubs/container" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FIXTURE/container.log"
store=$FIXTURE/store.json
full() { case "$1" in */*) echo "$1" ;; *) echo "docker.io/library/$1" ;; esac; }
has() { jq -e --arg name "$(full "$1")" 'any(.[]; .configuration.name == $name)' "$store" >/dev/null; }
# add <name> [<built>]
add() {
    jq --arg name "$(full "$1")" --arg built "${2:-}" '
        [.[] | select(.configuration.name != $name)] + [{configuration: {name: $name,
            descriptor: {annotations: (if $built == "" then {} else {"org.opencontainers.image.created": $built} end)}}}]' \
        "$store" >"$store.new" && mv "$store.new" "$store"
}
remove() { jq --arg name "$(full "$1")" '[.[] | select(.configuration.name != $name)]' "$store" >"$store.new" && mv "$store.new" "$store"; }
case "$1 ${2:-}" in
    '--version ') echo 'container CLI version 9.9.9 (build: release, commit: fixture)' ;;
    'system status') exit "$(cat "$FIXTURE/status.status")" ;;
    'system start') exit "$(cat "$FIXTURE/start.status")" ;;
    'image inspect') has "$3" ;;
    'image list') cat "$store" ;;
    'image delete')
        shift 2
        force=false
        [ "${1:-}" = --force ] && { force=true; shift; }
        status=0
        for name in "$@"; do
            has "$name" || { $force || status=1; continue; }
            remove "$name"
        done
        exit "$status"
        ;;
    build*)
        [ "$(cat "$FIXTURE/build.status")" = 0 ] || exit 1
        shift
        while [ $# -gt 1 ]; do
            case "$1" in
                -t) tag=$2; shift ;;
                -f) cp "$2" "$FIXTURE/built.Containerfile"; shift ;;
                --build-arg) base=${2#BASE=}; shift ;;
            esac
            shift
        done
        has "$base" || add "$base"
        clock=$(($(cat "$FIXTURE/clock") + 1))
        echo "$clock" >"$FIXTURE/clock"
        add "$tag" "$(printf '2026-01-01T00:%02d:%02dZ' $((clock / 60)) $((clock % 60)))"
        ;;
    run*)
        [ -e "$FIXTURE/run.vanish" ] && remove "${!#}"
        has "${!#}" || exit 1
        cat >"$FIXTURE/stdin.tar"
        exit "$(cat "$FIXTURE/run.status")"
        ;;
esac
EOF
cat >"$stubs/sysctl" <<'EOF'
#!/bin/bash
[ "$*" = '-n kern.hv_support' ] && cat "$FIXTURE/hv"
EOF
chmod +x "$stubs"/*
# Every directory on PATH but those holding a container, so the stub is the
# only one and removing it leaves none.
bare_path=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r dir; do [ -x "$dir/container" ] || printf '%s:' "$dir"; done)
export FIXTURE="$tmp" PATH="$stubs:${bare_path%:}"

reset() {
    rm -f "$tmp/container.log" "$tmp/stdin.tar" "$tmp/built.Containerfile" "$tmp/run.vanish"
    echo '[]' >"$tmp/store.json"
    echo 0 >"$tmp/clock"
    for file in status start run build; do echo 0 >"$tmp/$file.status"; done
    echo 1 >"$tmp/hv"
}
calls() { cat "$tmp/container.log" 2>/dev/null; }
call_count() { calls | grep -c "^$1"; }
# own <name> — whether the store holds <name>.
own() { jq -e --arg name "docker.io/library/$1" 'any(.[]; .configuration.name == $name)' "$tmp/store.json" >/dev/null && echo held || echo gone; }
tarred() { tar -tf "$tmp/stdin.tar" | grep -v '/$' | LC_ALL=C sort; }
in_clone() { (cd "$clone" && "$@"); }
image_of() { (cd "$clone" && . Tools/lib/linux-tests.sh && linux_tests_image "$1"); }
base=swift:9.8.7-noble
image=$(image_of HEAD)

# tree_with (<file> <content>)... — HEAD's tree with each <file> holding its
# <content>.
tree_with() (
    cd "$clone" && cp .git/index "$tmp/index" || exit 1
    while [ $# -gt 1 ]; do
        printf '%s\n' "$2" >"$tmp/blob" &&
            GIT_INDEX_FILE="$tmp/index" git update-index --cacheinfo "100644,$(git hash-object -w "$tmp/blob"),$1" || exit 1
        shift 2
    done
    GIT_INDEX_FILE="$tmp/index" git write-tree
)
# recipe <n> — a tree whose Containerfile is the nth recipe.
recipe() { tree_with Tools/linux-tests.Containerfile "FROM \${BASE} AS recipe$1"; }

# ---- the run ------------------------------------------------------------------

reset
in_clone "$test_linux" HEAD 2>/dev/null
check "a passing run's status" "$?" 0
check "the tar holds the commit's inputs and nothing else" "$(tarred)" "$inputs"
check "the run is in the tree's image" "$(calls | grep '^run ' | awk '{ print $NF }')" "$image"

reset
echo 7 >"$tmp/run.status"
in_clone "$test_linux" HEAD 2>/dev/null
check "a run whose tests fail exits 1" "$?" 1

# The content tree, as Tools/attest.sh gives it: what `git add -A` would stage.
reset
echo new >"$clone/KernovaKit/Sources/B.swift"
mkdir -p "$clone/KernovaKit/.build"
echo built >"$clone/KernovaKit/.build/out"
echo edit >"$clone/App/Main.swift"
tree=$(cd "$clone" && cp .git/index "$tmp/index" && GIT_INDEX_FILE="$tmp/index" git add -A && GIT_INDEX_FILE="$tmp/index" git write-tree)
in_clone "$test_linux" "$tree" 2>/dev/null
check "a content tree's tar holds its untracked input, not its ignored file or app code" "$(tarred)" \
    "$(printf '%s\n' "$inputs" KernovaKit/Sources/B.swift | LC_ALL=C sort)"
check "an app-only change leaves the image name" "$(image_of "$tree")" "$image"
rm -r "$clone/KernovaKit/Sources/B.swift" "$clone/KernovaKit/.build"
git -C "$clone" checkout -q -- App/Main.swift

# ---- the image ----------------------------------------------------------------

check "a Containerfile change renames the image" \
    "$([ "$(image_of "$(recipe 1)")" = "$image" ] && echo same || echo renamed)" renamed
check "a Swift release change renames the image" \
    "$([ "$(image_of "$(tree_with .swift-version 9.8.8)")" = "$image" ] && echo same || echo renamed)" renamed
check "a KernovaKit change leaves the image name" "$(image_of "$(tree_with KernovaKit/Sources/A.swift changed)")" "$image"

reset
echo 'RUN true' >>"$clone/Tools/linux-tests.Containerfile"
in_clone "$test_linux" HEAD 2>/dev/null
check "a missing image is built" "$(call_count build)" 1
check "the build takes the tree's Containerfile, not the disk's" "$(cat "$tmp/built.Containerfile")" 'FROM ${BASE}'
check "the build is on the tree's base" "$(calls | grep '^build ' | grep -c -- "--build-arg BASE=docker.io/library/$base")" 1
check "the run follows the build" "$(calls | grep -E '^(build|run) ' | awk '{ print $1 }' | paste -sd ' ' -)" 'build run'
git -C "$clone" checkout -q -- Tools/linux-tests.Containerfile

reset
in_clone "$test_linux" HEAD 2>/dev/null
: >"$tmp/container.log"
in_clone "$test_linux" HEAD 2>/dev/null
check "a present image is not built" "$(call_count build)" 0
check "a present image deletes nothing" "$(call_count 'image delete')" 0

# Two recipes in turn, as two worktrees run them.
reset
for tree in "$(recipe 1)" "$(recipe 2)" "$(recipe 1)" "$(recipe 2)"; do in_clone "$test_linux" "$tree" 2>/dev/null; done
check "two recipes in turn are built once each" "$(call_count build)" 2
check "two recipes in turn keep both images" "$(own "$(image_of "$(recipe 1)")") $(own "$(image_of "$(recipe 2)")")" 'held held'

reset
for n in 1 2 3 4; do in_clone "$test_linux" "$(recipe "$n")" 2>/dev/null; done
check "a fourth recipe deletes the oldest image" "$(for n in 1 2 3 4; do own "$(image_of "$(recipe "$n")")"; done | paste -sd ' ' -)" \
    'gone held held held'
check "the base stays" "$(own "$base")" held

# An image with no build time, as one built by an older container may be.
reset
jq '. + [{configuration: {name: "docker.io/library/kernova-linux-tests:000000000000", descriptor: {annotations: {}}}}]' \
    "$tmp/store.json" >"$tmp/store.new" && mv "$tmp/store.new" "$tmp/store.json"
for n in 1 2 3; do in_clone "$test_linux" "$(recipe "$n")" 2>/dev/null; done
check "an image with no build time is the oldest" \
    "$(own kernova-linux-tests:000000000000) $(for n in 1 2 3; do own "$(image_of "$(recipe "$n")")"; done | paste -sd ' ' -)" \
    'gone held held held'

# An image another session deleted after this run listed the store.
reset
for n in 1 2 3; do in_clone "$test_linux" "$(recipe "$n")" 2>/dev/null; done
cp "$stubs/container" "$tmp/container.real"
cat >"$stubs/container" <<EOF
#!/bin/bash
if [ "\$*" = 'image list --format json' ]; then
    jq '. + [{configuration: {name: "docker.io/library/kernova-linux-tests:000000000000",
        descriptor: {annotations: {"org.opencontainers.image.created": "2025-01-01T00:00:00Z"}}}}]' "\$FIXTURE/store.json"
else
    exec "$tmp/container.real" "\$@"
fi
EOF
chmod +x "$stubs/container"
err=$(in_clone "$test_linux" "$(recipe 4)" 2>&1 >/dev/null)
check "an image deleted elsewhere first: status" "$?" 0
check "an image deleted elsewhere first is no failure" "$(printf '%s\n' "$err" | grep -c 'Could not delete')" 0
mv "$tmp/container.real" "$stubs/container"

# ---- what the run needs ---------------------------------------------------------

reset
echo 1 >"$tmp/status.status"
in_clone "$test_linux" HEAD 2>/dev/null
check "a stopped service is started without a prompt" "$(calls | grep -c '^system start --enable-kernel-install$')" 1
check "a started service runs the tests" "$(call_count run)" 1

# cannot_run <name> <reason> — Tools/test-linux.sh, as set up, exits 3 with
# <reason> and runs nothing.
cannot_run() {
    err=$(in_clone "$test_linux" HEAD 2>&1 >/dev/null)
    check "$1: status" "$?" 3
    check "$1: message" "$(printf '%s\n' "$err" | tail -1)" "test-linux: the Linux tests need $2"
    check "$1 runs the tests" "$(call_count run)" 0
}

reset
echo 1 >"$tmp/status.status"
echo 1 >"$tmp/start.status"
cannot_run 'a service that will not start' "container's service, which \`container system start\` did not start"

reset
echo 0 >"$tmp/hv"
cannot_run 'no hypervisor' 'a hypervisor for container to run Linux in: this Mac has none (sysctl kern.hv_support is not 1)'

reset
mv "$stubs/container" "$tmp/container.away"
cannot_run 'no container' "Apple's container, which \`make setup\` installs with Homebrew"
mv "$tmp/container.away" "$stubs/container"

reset
echo 1 >"$tmp/build.status"
cannot_run 'an image that will not build' \
    "their image $image, which \`container build\` did not build on docker.io/library/$base (its output is above)"

reset
touch "$tmp/run.vanish"
err=$(in_clone "$test_linux" HEAD 2>&1 >/dev/null)
check "an image gone when the run starts: status" "$?" 3
check "an image gone when the run starts: message" "$(printf '%s\n' "$err" | tail -1)" \
    "test-linux: the Linux tests need their image $image, which another session deleted before this run started"

in_clone "$test_linux" 2>/dev/null
check "no tree: status" "$?" 2

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s test-linux: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
