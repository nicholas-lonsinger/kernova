#!/usr/bin/env bash
# Fixture tests for Tools/test-linux.sh and Tools/lib/linux-tests.sh: the tar a
# run feeds the container holds exactly the tree's Linux test inputs, untracked
# ones included and ignored ones not; the run's status passes through; the
# image is named by its recipe alone and built from the tree's recipe, not the
# disk's; a build deletes every other kernova-linux-tests image and the base
# it pulled, and nothing else; a stopped service is started, and nothing runs
# when the service will not start, container is absent, or the Mac has no
# hypervisor. Runs in a fixture clone with stub container and sysctl.

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
# $FIXTURE/images, one short name per line: `build` adds its tag and its base,
# `run` saves its stdin and exits $FIXTURE/run.status, `system status` and
# `system start` exit their files' statuses.
stubs="$tmp/stubs"
mkdir -p "$stubs"
cat >"$stubs/container" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FIXTURE/container.log"
short() { local name=${1#docker.io/library/}; printf '%s\n' "$name"; }
case "$1 ${2:-}" in
    '--version ') echo 'container CLI version 9.9.9 (build: release, commit: fixture)' ;;
    'system status') exit "$(cat "$FIXTURE/status.status")" ;;
    'system start') exit "$(cat "$FIXTURE/start.status")" ;;
    'image inspect') grep -qxF "$(short "$3")" "$FIXTURE/images" ;;
    'image list') cat "$FIXTURE/images" ;;
    'image delete')
        shift 2
        for name in "$@"; do grep -vxF "$(short "$name")" "$FIXTURE/images" >"$FIXTURE/images.new"; mv "$FIXTURE/images.new" "$FIXTURE/images"; done
        ;;
    build*)
        shift
        while [ $# -gt 1 ]; do
            case "$1" in
                -t) short "$2" >>"$FIXTURE/images"; shift ;;
                -f) cp "$2" "$FIXTURE/built.Containerfile"; shift ;;
                --build-arg) short "${2#BASE=}" >>"$FIXTURE/images"; shift ;;
            esac
            shift
        done
        sort -u -o "$FIXTURE/images" "$FIXTURE/images"
        ;;
    run*)
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
    rm -f "$tmp/container.log" "$tmp/stdin.tar" "$tmp/built.Containerfile"
    : >"$tmp/images"
    echo 0 >"$tmp/status.status"
    echo 0 >"$tmp/start.status"
    echo 0 >"$tmp/run.status"
    echo 1 >"$tmp/hv"
}
calls() { cat "$tmp/container.log" 2>/dev/null; }
call_count() { calls | grep -c "^$1" ; }
images() { LC_ALL=C sort "$tmp/images" | paste -sd ' ' -; }
tarred() { tar -tf "$tmp/stdin.tar" | grep -v '/$' | LC_ALL=C sort; }
in_clone() { (cd "$clone" && "$@"); }
image_of() { (cd "$clone" && . Tools/lib/linux-tests.sh && linux_tests_image "$1"); }
base=docker.io/library/swift:9.8.7-noble
image=$(image_of HEAD)

# ---- the run ------------------------------------------------------------------

reset
in_clone "$test_linux" HEAD 2>/dev/null
check "a passing run's status" "$?" 0
check "the tar holds the commit's inputs and nothing else" "$(tarred)" "$inputs"
check "the run is in the tree's image" "$(calls | grep '^run ' | awk '{ print $NF }')" "$image"

reset
echo 3 >"$tmp/run.status"
in_clone "$test_linux" HEAD 2>/dev/null
check "a failing run's status passes through" "$?" 3

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

# recipe_tree <file> <content> — HEAD's tree with <file> holding <content>.
recipe_tree() {
    (cd "$clone" && cp .git/index "$tmp/index" && printf '%s\n' "$2" >"$tmp/blob" &&
        GIT_INDEX_FILE="$tmp/index" git update-index --cacheinfo "100644,$(git hash-object -w "$tmp/blob"),$1" &&
        GIT_INDEX_FILE="$tmp/index" git write-tree)
}
check "a Containerfile change renames the image" \
    "$([ "$(image_of "$(recipe_tree Tools/linux-tests.Containerfile 'FROM ${BASE} AS other')")" = "$image" ] && echo same || echo renamed)" renamed
check "a Swift release change renames the image" \
    "$([ "$(image_of "$(recipe_tree .swift-version 9.8.8)")" = "$image" ] && echo same || echo renamed)" renamed
check "a KernovaKit change leaves the image name" "$(image_of "$(recipe_tree KernovaKit/Sources/A.swift changed)")" "$image"

reset
printf '%s\n' alpine:latest kernova-linux-tests:000000000000 kernova-linux-tests-other:1 >"$tmp/images"
echo 'RUN true' >>"$clone/Tools/linux-tests.Containerfile"
in_clone "$test_linux" HEAD 2>/dev/null
check "a missing image is built" "$(call_count build)" 1
check "the build takes the tree's Containerfile, not the disk's" "$(cat "$tmp/built.Containerfile")" 'FROM ${BASE}'
check "the build is on the tree's base" "$(calls | grep '^build ' | grep -c -- "--build-arg BASE=$base")" 1
check "a build leaves the new image and the images it did not make" "$(images)" "alpine:latest kernova-linux-tests-other:1 $image"
check "the run follows the build" "$(calls | grep -E '^(build|run) ' | awk '{ print $1 }' | paste -sd ' ' -)" 'build run'
git -C "$clone" checkout -q -- Tools/linux-tests.Containerfile

reset
printf '%s\n' "${base#docker.io/library/}" >"$tmp/images"
in_clone "$test_linux" HEAD 2>/dev/null
check "a build keeps a base it did not pull" "$(images)" "$image ${base#docker.io/library/}"

reset
echo "$image" >"$tmp/images"
in_clone "$test_linux" HEAD 2>/dev/null
check "a present image is not built" "$(call_count build)" 0
check "a present image deletes nothing" "$(call_count 'image delete')" 0

# ---- what the run needs ---------------------------------------------------------

reset
echo 1 >"$tmp/status.status"
in_clone "$test_linux" HEAD 2>/dev/null
check "a stopped service is started without a prompt" "$(calls | grep -c '^system start --enable-kernel-install$')" 1
check "a started service runs the tests" "$(call_count run)" 1

reset
echo 1 >"$tmp/status.status"
echo 1 >"$tmp/start.status"
err=$(in_clone "$test_linux" HEAD 2>&1 >/dev/null)
check "a service that will not start: status" "$?" 1
check "a service that will not start: message" "$(printf '%s\n' "$err" | tail -1)" \
    "test-linux: the Linux tests need container's service, which \`container system start\` did not start"
check "a service that will not start builds or runs" "$(calls | grep -cE '^(build|run) ')" 0

reset
echo 0 >"$tmp/hv"
err=$(in_clone "$test_linux" HEAD 2>&1 >/dev/null)
check "no hypervisor: status" "$?" 1
check "no hypervisor: message" "$err" \
    'test-linux: the Linux tests need a hypervisor for container to run Linux in: this Mac has none (sysctl kern.hv_support is not 1)'
check "no hypervisor calls container" "$(calls)" ''

reset
mv "$stubs/container" "$tmp/container.away"
err=$(in_clone "$test_linux" HEAD 2>&1 >/dev/null)
check "no container: status" "$?" 1
check "no container: message" "$err" \
    "test-linux: the Linux tests need Apple's container, which \`make setup\` installs with Homebrew"
mv "$tmp/container.away" "$stubs/container"

in_clone "$test_linux" 2>/dev/null
check "no tree: status" "$?" 2

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s test-linux: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
