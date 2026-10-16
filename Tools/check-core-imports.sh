#!/usr/bin/env bash
# KernovaCore is tested without the app as its host, so its code must not use
# AppKit or Virtualization, and the compiler cannot hold that: Virtualization.h
# imports <Cocoa/Cocoa.h> under `export *`, so a module that looks unrelated
# can re-export AppKit. Every module a KernovaCore file imports is therefore on
# an allowlist, not off a deny-list.
#
# Sources may import only `core_modules`; tests may also import
# `test_modules`. A new entry names a module that re-exports neither AppKit nor
# Virtualization. One that merely imports AppKit, as KernovaKit does, exposes
# none of it: the package's MemberImportVisibility setting keeps AppKit's
# members out as well as its types.
#
# Reports every violation before failing, so one run fixes them all.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

core_modules='Foundation KernovaKit KernovaLogging'
test_modules='Testing KernovaCore KernovaTestSupport'

sources_root='KernovaCore/Sources'
tests_root='KernovaCore/Tests'

# Every spelling of an import Swift accepts: attributes with and without
# arguments (`@testable`, `@_spi(Private)`), an access-level modifier, an
# import kind (`import class AppKit.NSImage`), and a submodule. The module is
# the first component of what follows.
attribute='@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+'
access='(public|package|internal|fileprivate|private)[[:space:]]+'
kind='(class|struct|enum|protocol|typealias|func|var|let)[[:space:]]+'
import_pattern="^[[:space:]]*($attribute)*($access)?import[[:space:]]+($kind)?[A-Za-z_]"

violations=""
scanned=0

# check <root> <allowed modules>
check() {
    local root=$1 allowed=" $2 " file line number module
    while IFS= read -r file; do
        scanned=$((scanned + 1))
        while IFS=: read -r number line; do
            module=$(printf '%s\n' "$line" | sed -E "s/^[[:space:]]*($attribute)*($access)?import[[:space:]]+($kind)?//; s/[^A-Za-z0-9_].*//")
            if [[ $allowed != *" $module "* ]]; then
                violations="$violations  $file:$number imports $module"$'\n'
            fi
        done < <(grep -nE "$import_pattern" "$file")
    done < <(git ls-files "$root/*.swift")
}

check "$sources_root" "$core_modules"
check "$tests_root" "$core_modules $test_modules"

if [ "$scanned" -eq 0 ]; then
    echo "check-core-imports: no tracked Swift files under $sources_root or $tests_root" >&2
    exit 1
fi

if [ -n "$violations" ]; then
    echo "check-core-imports: KernovaCore imports a module off its allowlist:" >&2
    printf '%s' "$violations" >&2
    echo "  allowed in sources: $core_modules; in tests, also: $test_modules" >&2
    exit 1
fi

pass "core imports: every KernovaCore import is on its allowlist ($core_modules)"
