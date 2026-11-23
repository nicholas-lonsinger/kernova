# The machine's tool cache: what this repository's scripts build from pinned
# sources or from the checkout — its tools, and the Linux guest agent — each
# installed whole into an entry named by a hash of everything that determines
# it, so a build whose inputs are unchanged runs once per machine, whatever
# the checkout, and CI caches an entry under its name. Sourced, never run:
#
#     . "$root/Tools/lib/tool-cache.sh"
#     inputs=(swift-protobuf "$revision" -- Tools/install-protoc.sh)
#     dir=$(tool_dir "${inputs[@]}")                                # where it is or would be
#     dir=$(tool_install build_protoc verify_protoc "${inputs[@]}")  # installed
#
# Every entry under the cache root is this file's. An install builds and
# verifies an entry in a staging directory beside it, then renames it into
# place, so an entry is whole and verified or absent; two installs of one
# entry both end with the one whose rename landed first. Each lookup marks its
# entry used, and an install that builds removes the entries unused for 30
# days and every entry of its name but the ten used last, which bounds what an
# entry built from the checkout leaves behind as each edit names a new one.

# shellcheck shell=bash

tool_cache_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# tool_cache_root — the directory every entry is in; fails when there is no
# home directory to put it under.
tool_cache_root() {
    local caches
    if [ "$(uname -s)" = Darwin ]; then
        caches=${HOME:+$HOME/Library/Caches}
    else
        caches=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
    fi
    if [ -z "$caches" ]; then
        echo 'tool_cache_root: HOME is unset or empty, so the tool cache has no directory' >&2
        return 1
    fi
    printf '%s\n' "$caches/kernova-dev"
}

# tool_dir <name> [<value>...] -- [<path>...] — the entry <name> installs
# into: <name>-<16 hex digits> under the cache root, the digits hashing
# <name>, each <value>, each <path> — a file, or every file under a directory,
# named relative to the repository root and read for its content, through
# symbolic links — and the Swift toolchain `swift` resolves in the repository
# root, where every tool here builds: a swiftly proxy on PATH picks its
# toolchain by directory. A build with another toolchain names it among its
# values (tool_swift_identity).
tool_dir() {
    local root key
    root=$(tool_cache_root) || return
    key=$(tool_key "$@") || return
    printf '%s/%s-%s\n' "$root" "$1" "$key"
}

tool_key() (
    set -o pipefail
    cd "$tool_cache_repo" || exit
    manifest=''
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        manifest+="value $1"$'\n'
        shift
    done
    if [ $# -eq 0 ]; then
        echo 'tool_dir: no -- after the name and values' >&2
        exit 2
    fi
    shift
    for path in "$@"; do
        if [ ! -e "$path" ]; then
            echo "tool_dir: $path is not in $tool_cache_repo" >&2
            exit 1
        fi
    done
    if [ $# -gt 0 ]; then
        # One hashing process for every file, whose lines are `<hash>  <file>`
        # in the order it was given them.
        hashes=$(find -L "$@" -type f | LC_ALL=C sort | tr '\n' '\0' | xargs -0 -r "${tool_sha256[@]}") || exit
        if [ -n "$hashes" ]; then
            manifest+=$(awk '
                substr($0, 65, 2) != "  " { print "tool_dir: cannot read the hash of " $0 > "/dev/stderr"; exit 1 }
                { print "file " substr($0, 67) " " substr($0, 1, 64) }' <<<"$hashes")$'\n' || exit
        fi
    fi
    manifest+="toolchain $(tool_toolchain)"$'\n' || exit
    printf '%s' "$manifest" | "${tool_sha256[@]}" | cut -c 1-16
)

# tool_swift_identity <swift command>... — the toolchain `<swift command>
# -print-target-info` runs: its compiler, the triple it targets less the OS
# version, and where it is installed.
tool_swift_identity() {
    "$@" -print-target-info | grep -E '"(compilerVersion|unversionedTriple|runtimeResourcePath)"'
}

# The toolchain a build here uses, and on macOS the SDK it builds against.
tool_toolchain() {
    tool_swift_identity swift || return
    if [ "$(uname -s)" = Darwin ]; then
        xcrun --sdk macosx --show-sdk-build-version || return
    fi
}

if command -v sha256sum >/dev/null 2>&1; then
    tool_sha256=(sha256sum)
else
    tool_sha256=(shasum -a 256)
fi

# tool_install <build> <verify> <name> [<value>...] -- [<path>...] — installs
# the entry tool_dir names for the rest, unless it is there, and prints its
# directory. `<build> <entry> <work>` writes the tool's files into <entry>
# and may use <work>, both empty directories removed afterwards; `<verify>
# <entry>` succeeds only when the files there run. Both run in the repository
# root, where the entry's toolchain is read. Fails, installing nothing, when
# either fails, when the entry's inputs changed while it built, or when it is
# interrupted.
tool_install() (
    set -eo pipefail
    build=$1 verify=$2
    shift 2
    cd "$tool_cache_repo"
    dir=$(tool_dir "$@")
    if [ -d "$dir" ]; then
        touch -c "$dir"
        printf '%s\n' "$dir"
        exit 0
    fi
    mkdir -p "${dir%/*}"
    staging=$(mktemp -d "${dir%/*}/.${dir##*/}.XXXXXX")
    failure='the build failed' status=0
    trap 'status=$?; rm -rf "$staging"; [ "$status" -eq 0 ] || echo "tool_install: ${dir##*/}: $failure" >&2' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir "$staging/entry" "$staging/work"
    "$build" "$staging/entry" "$staging/work"
    failure='the build does not run'
    "$verify" "$staging/entry"
    failure='its inputs changed while it built; run it again'
    [ "$(tool_dir "$@")" = "$dir" ]
    failure='it could not be renamed into place'
    # rename(2), which fails when the entry exists: a concurrent install of
    # the same inputs published it first.
    perl -e 'rename($ARGV[0], $ARGV[1]) or $!{EEXIST} or $!{ENOTEMPTY} or die "$ARGV[1]: $!\n"' \
        "$staging/entry" "$dir"
    find "${dir%/*}" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + ||
        echo "tool_install: the entries unused for 30 days beside ${dir##*/} were not all removed" >&2
    digits=''
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do digits+='[0-9a-f]'; done
    # shellcheck disable=SC2012,SC2086 # $digits globs; an entry's name is <name>-<16 hex digits>
    ls -dt "${dir%/*}/$1"-$digits | tail -n +11 | while IFS= read -r old; do rm -rf "$old"; done ||
        echo "tool_install: the entries of $1 but the ten used last were not all removed" >&2
    printf '%s\n' "$dir"
)
