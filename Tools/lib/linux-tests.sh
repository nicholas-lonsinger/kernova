# KernovaKit's Linux tests as every route runs them — `make test-linux`,
# `make attest` and CI's Linux job: in the image Tools/linux-tests.Containerfile
# describes, over a tar of the tree that holds only linux_tests_paths. That
# tree is all a run reads from the checkout, so a build or test that reads any
# other file fails instead of passing under a key that does not name it. The
# linux_tests_container_* functions are the Mac's side, in Apple's container.
# Sourced, never run; run from inside the checkout.

# shellcheck shell=bash

# linux_tests_paths — what the Linux tests read from the checkout, and what
# runs them. The `paths` filter of .github/workflows/portable.yml names the
# same paths (Tools/check-linux-tests-paths.sh).
linux_tests_paths() {
    printf '%s\n' \
        .swift-version \
        Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
        KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk/agent-disk.sh \
        KernovaKit \
        Tools/lib/linux-tests.sh \
        Tools/lib/package-pins.sh \
        Tools/linux-tests.Containerfile \
        Tools/test-linux.sh
}

# linux_tests_tree <tree-ish> — the tree of <tree-ish>'s linux_tests_paths,
# built in a scratch index.
linux_tests_tree() {
    local scratch tree status
    scratch=$(mktemp -d) || return 1
    # shellcheck disable=SC2046 # one path per word
    tree=$(git ls-tree -r --full-tree "$1" -- $(linux_tests_paths) |
        GIT_INDEX_FILE="$scratch/index" git update-index --index-info &&
        GIT_INDEX_FILE="$scratch/index" git write-tree)
    status=$?
    rm -rf "$scratch"
    [ "$status" -eq 0 ] && printf '%s\n' "$tree"
}

# linux_tests_base <tree-ish> — the image the tests' image is built on: the
# swift.org image of the release <tree-ish>'s .swift-version pins.
linux_tests_base() {
    local version
    version=$(git cat-file blob "$1:.swift-version" | tr -d '[:space:]') && [ -n "$version" ] || return 1
    printf 'docker.io/library/swift:%s-noble\n' "$version"
}

# linux_tests_image <tree-ish> — the image the tests over <tree-ish> run in,
# named by a hash of its recipe: the Containerfile and the base.
linux_tests_image() {
    local recipe
    recipe=$(git rev-parse "$1:Tools/linux-tests.Containerfile" && linux_tests_base "$1") || return 1
    printf 'kernova-linux-tests:%s\n' "$(git hash-object --stdin <<<"$recipe" | cut -c 1-12)"
}

# linux_tests_build_image <cli> <tree-ish> [<flag>...] — builds the image
# linux_tests_image names from <tree-ish>'s recipe with <cli>, `container` or
# `docker`, passing `<cli> build` the flags.
linux_tests_build_image() {
    local cli=$1 tree=$2 image base context status
    shift 2
    image=$(linux_tests_image "$tree") && base=$(linux_tests_base "$tree") || return 1
    context=$(mktemp -d) || return 1
    git cat-file blob "$tree:Tools/linux-tests.Containerfile" >"$context/Containerfile" &&
        "$cli" build "$@" --build-arg "BASE=$base" -t "$image" -f "$context/Containerfile" "$context"
    status=$?
    rm -rf "$context"
    return "$status"
}

# linux_tests_run <cli> <tree-ish> <image> [<flag>...] — runs the tests over
# <tree-ish> in <image> with <cli>, passing `<cli> run` the flags, and returns
# their status.
linux_tests_run() (
    set -o pipefail
    cli=$1 image=$3
    tree=$(linux_tests_tree "$2") || exit 1
    shift 3
    git archive --format=tar "$tree" | "$cli" run -i --rm "$@" "$image"
)

# linux_tests_container_missing — on stdout, what this Mac lacks to run the
# tests in Apple's container; nothing when it lacks nothing.
linux_tests_container_missing() {
    if ! command -v container >/dev/null 2>&1; then
        echo "Apple's container, which \`make setup\` installs with Homebrew"
    elif [ "$(sysctl -n kern.hv_support 2>/dev/null)" != 1 ]; then
        echo 'a hypervisor for container to run Linux in: this Mac has none (sysctl kern.hv_support is not 1)'
    fi
}

# linux_tests_container_up — linux_tests_container_missing, then starts
# container's service when it is not running. Fails, printing what is missing
# on stdout, when the tests cannot run here.
linux_tests_container_up() {
    local missing
    missing=$(linux_tests_container_missing)
    if [ -n "$missing" ]; then
        printf '%s\n' "$missing"
        return 1
    fi
    container system status >/dev/null 2>&1 && return 0
    echo "Starting container's service" >&2
    if ! container system start --enable-kernel-install >&2; then
        echo "container's service, which \`container system start\` did not start"
        return 1
    fi
}

# The images this Mac keeps: the three built last, by the build time container
# records for each (its index annotation org.opencontainers.image.created).
LINUX_TESTS_IMAGES_KEPT=3

# linux_tests_container_image <tree-ish> — makes sure this Mac holds the image
# for <tree-ish>'s recipe, building it when it does not, then deletes every
# kernova-linux-tests image past the LINUX_TESTS_IMAGES_KEPT built last, and
# each base a build here pulled that no kept image is built on. Two labels
# on each image say what that takes: the base it is built on, and whether a
# build here pulled that base — which a build on a base that is already here
# takes from the images built on it. Fails, printing what is missing on
# stdout, when the image cannot be built; a deletion that fails is reported
# and the image stays usable.
linux_tests_container_image() {
    local image base pulled=true
    if ! { image=$(linux_tests_image "$1") && base=$(linux_tests_base "$1"); }; then
        echo "a recipe for their image in $1: Tools/linux-tests.Containerfile and .swift-version"
        return 1
    fi
    container image inspect "$image" >/dev/null 2>&1 && return 0
    if container image inspect "$base" >/dev/null 2>&1; then
        pulled=$(container image list --format json | jq -r --arg base "$base" '
            any(.[].variants[]?.config.config.Labels // {};
                .["app.kernova.linux-tests.base"] == $base and .["app.kernova.linux-tests.base-pulled"] == "true")')
    fi
    echo "Building $image on $base" >&2
    if ! linux_tests_build_image container "$1" --platform linux/arm64 --progress plain \
        --label "app.kernova.linux-tests.base=$base" --label "app.kernova.linux-tests.base-pulled=$pulled" >&2; then
        echo "their image $image, which \`container build\` did not build on $base (its output is above)"
        return 1
    fi
    linux_tests_container_prune ||
        echo "Could not delete the kernova-linux-tests images past the $LINUX_TESTS_IMAGES_KEPT built last" >&2
    return 0
}

# linux_tests_container_prune — the deletions linux_tests_container_image
# describes. Deleting an image another session deleted first is no failure.
linux_tests_container_prune() (
    set -o pipefail
    stale=$(container image list --format json | jq -r --argjson kept "$LINUX_TESTS_IMAGES_KEPT" '
        [.[] | select(.configuration.name | startswith("docker.io/library/kernova-linux-tests:"))
            | (.variants[0].config.config.Labels // {}) as $labels
            | {name: .configuration.name,
               built: (.configuration.descriptor.annotations["org.opencontainers.image.created"] // ""),
               base: $labels["app.kernova.linux-tests.base"],
               pulled: ($labels["app.kernova.linux-tests.base-pulled"] == "true")}]
        | sort_by(.built) | reverse
        | .[:$kept] as $keep | .[$kept:] as $gone
        | ($gone[].name),
          ([$gone[] | select(.pulled) | .base] | unique[] | select(. as $base | all($keep[]; .base != $base)))') ||
        exit 1
    # shellcheck disable=SC2086 # one image name per word
    [ -z "$stale" ] || container image delete --force $stale >&2
)
