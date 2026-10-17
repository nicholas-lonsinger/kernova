#!/usr/bin/env bash
# Code under test reads two declarations from the main bundle, which in a test
# run is the test host, so the host must carry the app's own:
#
# - Cocoa scripting loads its dictionary from Info.plist's
#   OSAScriptingDefinition, naming an sdef among the bundle's resources, once
#   NSAppleScriptEnabled turns scripting on. A bundle missing either loads no
#   dictionary, and nothing fails to compile.
# - `UTType(exportedAs:)` expects its identifier in the main bundle's
#   UTExportedTypeDeclarations and logs a "was expected to be declared"
#   warning when it is missing. Declared there, the type the host sees is the
#   app's, not whatever a Kernova.app Launch Services last registered says.
#
# Checks each target's Info.plist (the INFOPLIST_FILE its xcconfig assigns):
# that both carry the scripting keys, that the sdef the plist names is one
# tracked file in the app's folder the host takes into its bundle by membership
# exception, and that the host's UTExportedTypeDeclarations equal the app's.
# Reports every violation before failing.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

pbxproj="Kernova.xcodeproj/project.pbxproj"
targets=(Kernova KernovaTestHost)

status=0
fail_with() {
    echo "check-test-host-declarations: $*" >&2
    status=1
}

# The sdef path relative to the app's folder, as the host's membership
# exception names it, and the app's exported types; both set from the app's
# own plist.
sdef_rel=""
app_types=""

for target in "${targets[@]}"; do
    xcconfig="Config/Targets/$target.xcconfig"
    plist=$(sed -n 's/^[[:space:]]*INFOPLIST_FILE[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$xcconfig" 2>/dev/null | head -1)
    if [ -z "$plist" ] || [ ! -f "$plist" ]; then
        fail_with "$xcconfig assigns no readable INFOPLIST_FILE"
        continue
    fi

    types=$(plutil -extract UTExportedTypeDeclarations xml1 -o - "$plist" 2>/dev/null)
    if [ -z "$types" ]; then
        fail_with "$plist: UTExportedTypeDeclarations is missing"
    elif [ "$target" = "Kernova" ]; then
        app_types=$types
    elif [ -n "$app_types" ] && [ "$types" != "$app_types" ]; then
        fail_with "$plist: UTExportedTypeDeclarations differ from the app's:"
        diff <(printf '%s\n' "$app_types") <(printf '%s\n' "$types") >&2
    fi

    enabled=$(plutil -extract NSAppleScriptEnabled raw -o - "$plist" 2>/dev/null)
    if [ "$enabled" != "true" ]; then
        fail_with "$plist: NSAppleScriptEnabled is not true"
    fi

    declared=$(plutil -extract OSAScriptingDefinition raw -o - "$plist" 2>/dev/null)
    if [ -z "$declared" ]; then
        fail_with "$plist: OSAScriptingDefinition is missing"
        continue
    fi

    matches=$(git ls-files 'Kernova/*' | awk -F/ -v name="$declared" '$NF == name')
    if [ "$(grep -c . <<<"$matches")" -ne 1 ]; then
        fail_with "$plist: OSAScriptingDefinition names $declared, which is not exactly one tracked file under Kernova/"
        continue
    fi

    if [ "$target" = "Kernova" ]; then
        sdef_rel=${matches#Kernova/}
    elif [ -n "$sdef_rel" ] && [ "${matches#Kernova/}" != "$sdef_rel" ]; then
        fail_with "$plist names $declared; the app ships $sdef_rel"
    fi
done

if [ -n "$sdef_rel" ]; then
    # The exception set on the app's folder for the host is what puts the
    # file in the host's bundle; the app's own exceptions exclude.
    exception=$(awk -v want="$sdef_rel" '
        /Exceptions for "Kernova" folder in "KernovaTestHost" target \*\/ = \{/ { inside = 1 }
        inside && $0 ~ /^\t\t\};/ { inside = 0 }
        inside { gsub(/[\t ,]/, ""); if ($0 == want) print }
    ' "$pbxproj")
    if [ -z "$exception" ]; then
        fail_with "$pbxproj: KernovaTestHost takes no membership of Kernova/$sdef_rel"
    fi
fi

if [ "$status" -eq 0 ]; then
    pass "test host declarations: the app and the test host both declare and bundle Kernova/$sdef_rel, and export the same types"
fi
exit "$status"
