#!/usr/bin/env bash
# KernovaCore is tested without the app as its host, so its code must not use
# AppKit or Virtualization, and the compiler cannot hold that: Virtualization.h
# imports <Cocoa/Cocoa.h> under `export *`, so a module that looks unrelated
# can re-export AppKit. Every module a KernovaCore file imports is therefore on
# an allowlist, not off a deny-list.
#
# The `KernovaCore` target may import only `core_modules`;
# `KernovaCoreTestSupport` may also import `support_modules`, and
# `KernovaCoreTests` `test_modules`. Every entry is a module that reaches none
# of AppKit, SwiftUI or Virtualization — importing it alone leaves `NSView`,
# `SwiftUI.View` and `VZVirtualMachine` out of scope — and a new one is checked
# the same way; what a module merely imports is KernovaCore/Package.swift's
# MemberImportVisibility setting's concern.
#
# The compiler's own parser lists each file's imports
# (`-emit-imported-modules`), so every spelling, comments and string literals,
# and `#if` are read as a build reads them. `#if` is evaluated twice, with and
# without DEBUG, since the package builds in both configurations. One batched
# run per configuration answers whether anything is off the allowlist; only
# then does a per-file pass name the files.
#
# Reports every violation before failing, so one run fixes them all, and fails
# when a file cannot be parsed rather than passing it unread.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

core_modules='Foundation KernovaKit KernovaLogging AppIntents AVFoundation CoreServices CoreSpotlight CryptoKit ImageIO IOKit Security ServiceManagement Synchronization System UniformTypeIdentifiers'
test_modules='Testing KernovaCore KernovaCoreTestSupport KernovaTestSupport SwiftProtobuf CoreGraphics Observation'
support_modules='Testing KernovaCore KernovaTestSupport CoreGraphics Observation'

sources_root='KernovaCore/Sources/KernovaCore'
support_root='KernovaCore/Sources/KernovaCoreTestSupport'
tests_root='KernovaCore/Tests/KernovaCoreTests'

swiftc=$(xcrun --find swiftc) || { echo "check-core-imports: swiftc not found" >&2; exit 1; }

# The configurations a build evaluates `#if` under.
configurations=('-D SWIFT_PACKAGE' '-D SWIFT_PACKAGE -D DEBUG')

violations=""
failed=0

# imported <flags> <file>... — the union of the files' imports, one per line.
imported() {
    local flags=$1
    shift
    # shellcheck disable=SC2086 # the flags are words by design
    "$swiftc" -frontend -emit-imported-modules -swift-version 6 -module-name CoreImports $flags "$@" -o -
}

# off_list <allowed> — the lines of stdin not on the allowlist.
off_list() {
    local allowed=" $1 " module
    while IFS= read -r module; do
        [ -n "$module" ] && [[ $allowed != *" $module "* ]] && echo "$module"
    done
    return 0
}

# check <root> <allowed modules>
check() {
    local root=$1 allowed=$2 flags file found files=()
    while IFS= read -r file; do files+=("$file"); done < <(git ls-files "$root/*.swift")
    if [ "${#files[@]}" -eq 0 ]; then
        echo "check-core-imports: no tracked Swift files under $root" >&2
        failed=1
        return
    fi
    for flags in "${configurations[@]}"; do
        if ! found=$(imported "$flags" "${files[@]}"); then
            echo "check-core-imports: the compiler could not read the imports of $root ($flags)" >&2
            failed=1
            return
        fi
        [ -n "$(off_list "$allowed" <<<"$found")" ] || continue
        for file in "${files[@]}"; do
            found=$(imported "$flags" "$file" | off_list "$allowed" | paste -sd ' ' -)
            [ -n "$found" ] && violations="$violations  $file imports $found (with $flags)"$'\n'
        done
    done
}

check "$sources_root" "$core_modules"
check "$support_root" "$core_modules $support_modules"
check "$tests_root" "$core_modules $test_modules"

if [ -n "$violations" ]; then
    echo "check-core-imports: KernovaCore imports a module off its allowlist:" >&2
    printf '%s' "$violations" | sort -u >&2
    echo "  allowed in $sources_root: $core_modules; in $support_root, also: $support_modules;" \
        "in $tests_root, also: $test_modules" >&2
    failed=1
fi

[ "$failed" -eq 0 ] || exit 1

pass "core imports: every KernovaCore import is on its allowlist ($core_modules)"
