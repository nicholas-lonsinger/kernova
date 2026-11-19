# The machine's tool cache: the tools this repository's scripts build from
# pinned sources, each installed whole into an entry named by a hash of
# everything that determines it, so a build whose inputs are unchanged runs
# once per machine, whatever the checkout, and CI caches an entry under its
# name. Sourced, never run:
#
#     . "$root/Tools/lib/tool-cache.sh"
#     inputs=(periphery 3.8.0 -- Tools/install-periphery.sh Tools/periphery.patch)
#     dir=$(tool_dir "${inputs[@]}")                                  # where it is or would be
#     dir=$(tool_install build_periphery verify_periphery "${inputs[@]}")  # installed
#
# Every entry under the cache root is this file's. An install builds and
# verifies an entry in a staging directory beside it, then renames it into
# place, so an entry is whole and verified or absent; two installs of one
# entry both end with the one whose rename landed first. Each lookup marks its
# entry used, and an install that builds removes the entries unused for 30
# days.

# shellcheck shell=bash

tool_cache_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# tool_cache_root — the directory every entry is in.
tool_cache_root() {
    if [ "$(uname -s)" = Darwin ]; then
        printf '%s\n' "$HOME/Library/Caches/kernova-dev"
    else
        printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/kernova-dev"
    fi
}

# tool_dir <name> [<value>...] -- [<path>...] — the entry <name> installs
# into: <name>-<16 hex digits> under the cache root, the digits hashing
# <name>, each <value>, each <path> — a file, or every file under a directory,
# named relative to the repository root and read for its content — and the
# Swift toolchain on PATH, which every tool here builds with.
tool_dir() {
    local key
    key=$(tool_key "$@") || return
    printf '%s/%s-%s\n' "$(tool_cache_root)" "$1" "$key"
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
        files=$(find "$@" -type f | LC_ALL=C sort) || exit
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            manifest+="file $file $(tool_sha256 <"$file")"$'\n' || exit
        done <<<"$files"
    fi
    manifest+="toolchain $(tool_toolchain)"$'\n' || exit
    printf '%s' "$manifest" | tool_sha256 | cut -c 1-16
)

# The toolchain a build here uses: the `swift` on PATH, by its compiler, the
# triple it targets less the OS version, and where it is installed, which a
# macOS build of Periphery links libIndexStore from by absolute path — and on
# macOS the SDK it builds against.
tool_toolchain() {
    swift -print-target-info | grep -E '"(compilerVersion|unversionedTriple|runtimeResourcePath)"' || return
    if [ "$(uname -s)" = Darwin ]; then
        xcrun --sdk macosx --show-sdk-build-version || return
    fi
}

tool_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d ' ' -f 1
    else
        shasum -a 256 | cut -d ' ' -f 1
    fi
}

# tool_install <build> <verify> <name> [<value>...] -- [<path>...] — installs
# the entry tool_dir names for the rest, unless it is there, and prints its
# directory. `<build> <entry> <work>` writes the tool's files into <entry>
# and may use <work>, both empty directories removed afterwards; `<verify>
# <entry>` succeeds only when the files there run. Fails, installing nothing,
# when either fails, when the entry's inputs changed while it built, or when
# it is interrupted.
tool_install() (
    set -eo pipefail
    build=$1 verify=$2
    shift 2
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
    printf '%s\n' "$dir"
)
