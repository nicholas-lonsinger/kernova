#!/usr/bin/env bash
# Every PBXShellScriptBuildPhase in project.pbxproj is one line calling a
# tracked Tools/ script — "${SRCROOT}/Tools/<name>.sh", optionally with
# arguments — and nothing else. A program typed into Xcode's Run Script
# editor lives as one escaped string inside the project file, which `make
# lint` reaches with neither shellcheck nor `bash -n`. Moving the body into
# Tools/ puts it under both.
#
# Reports every violation before failing, so one run fixes them all.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

pbxproj="Kernova.xcodeproj/project.pbxproj"

if [ ! -f "$pbxproj" ]; then
    echo "check-build-phases: $pbxproj is missing" >&2
    exit 1
fi

# Each phase as "<owning target> / <phase name>\t<shellScript as written>".
# Pass 1 maps phase IDs to the target that runs them, so a violation names
# the phase the way Xcode's navigator does rather than a bare hex ID.
phases=$(awk '
    FNR == NR {
        if ($0 ~ /^\t\t\tisa = PBXNativeTarget;$/) { in_target = 1; count = 0; next }
        if (!in_target) next
        if ($0 ~ /^\t\t\};$/) {
            for (i = 1; i <= count; i++) owner[ids[i]] = target
            in_target = 0
            next
        }
        if ($0 ~ /^\t\t\tbuildPhases = \($/) { in_phases = 1; next }
        if (in_phases) {
            if ($0 ~ /^\t\t\t\);$/) { in_phases = 0; next }
            ids[++count] = $1
            next
        }
        if ($0 ~ /^\t\t\tname = /) {
            target = $0
            sub(/^\t\t\tname = /, "", target)
            sub(/;$/, "", target)
            gsub(/"/, "", target)
        }
        next
    }

    /^\t\t[0-9A-Fa-f]+ \/\* / && !in_phase { pending = $1 }
    /^\t\t\tisa = PBXShellScriptBuildPhase;$/ {
        in_phase = 1
        id = pending
        name = ""
        script = ""
        next
    }
    in_phase {
        if ($0 ~ /^\t\t\};$/) {
            label = (name != "") ? name : id
            if (id in owner) label = owner[id] " / " label
            printf "%s\t%s\n", label, script
            in_phase = 0
            next
        }
        if ($0 ~ /^\t\t\tname = /) {
            name = $0
            sub(/^\t\t\tname = /, "", name)
            sub(/;$/, "", name)
            gsub(/"/, "", name)
            next
        }
        if ($0 ~ /^\t\t\tshellScript = /) {
            script = $0
            sub(/^\t\t\tshellScript = /, "", script)
            sub(/;$/, "", script)
            next
        }
    }
' "$pbxproj" "$pbxproj")

violations=""
violation() { violations="$violations  $1"$'\n'; }

# The one accepted line, spelled as it appears in the phase.
call='^"\$\{SRCROOT\}/Tools/([A-Za-z0-9._-]+\.sh)"([[:space:]].*)?$'

while IFS=$'\t' read -r label script; do
    [ -n "$label" ] || continue

    # shellScript holds one plist string: outer quotes, \" for each embedded
    # quote, \n for each line break.
    body=${script#\"}
    body=${body%\"}
    body=$(printf '%s\n' "$body" | awk '{ gsub(/\\n/, "\n"); gsub(/\\"/, "\""); print }')

    lines=$(printf '%s\n' "$body" | grep -c '[^[:space:]]')
    if [ "$lines" -eq 0 ]; then
        violation "$label: empty — delete the phase or give it a Tools/ call"
        continue
    fi
    if [ "$lines" -ne 1 ]; then
        violation "$label: $lines lines — move the program into a Tools/*.sh script and call it"
        continue
    fi

    line=$(printf '%s\n' "$body" | grep '[^[:space:]]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [[ ! $line =~ $call ]]; then
        violation "$label: $line — expected a \"\${SRCROOT}/Tools/<name>.sh\" call"
        continue
    fi

    tool="Tools/${BASH_REMATCH[1]}"
    if ! git ls-files --error-unmatch -- "$tool" >/dev/null 2>&1; then
        violation "$label: calls $tool, which is not a tracked file"
    fi
done <<<"$phases"

if [ -n "$violations" ]; then
    echo "check-build-phases: $pbxproj holds shell build phases lint cannot see:" >&2
    printf '%s' "$violations" >&2
    exit 1
fi

pass "build phases: every shell phase is a one-line call into Tools/"
