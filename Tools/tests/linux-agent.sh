#!/usr/bin/env bash
# Fixture tests for Tools/lib/linux-agent.sh: the label written into, and read
# from, CKernovaAgentVersion.c compiled for aarch64 Linux, checked against
# objdump's reading of the object; and which targets' directories a package
# description puts in the agent's build.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=../lib/linux-agent.sh
. "$ROOT/Tools/lib/linux-agent.sh"

if [ "$(uname -s)" = Darwin ]; then tools=(xcrun); else tools=(); fi
compile() { # <source> <object>
    "${tools[@]}" clang --target=aarch64-unknown-linux-gnu -O2 -c "$1" \
        -I "$ROOT/KernovaKit/Sources/CKernovaAgentVersion/include" -o "$2"
}

# The label section's bytes as objdump reads them, as text up to the first NUL,
# then the count of bytes the section holds.
objdump_label() { # <object>
    "${tools[@]}" objdump -s -j "$LINUX_AGENT_LABEL_SECTION" "$1" | awk '
        /^ [0-9a-f]+ / { for (i = 2; i <= 5 && $i ~ /^[0-9a-f]+$/; i++) hex = hex $i }
        END { print hex }' | perl -ne 'chomp; my $b = pack("H*", $_); my $n = length $b; $b =~ s/\0.*//s; print "$b $n\n"'
}

# Every section but the label's, and the section headers, as objdump reads
# them, less the lines that name the file.
other_sections() { # <object>
    { "${tools[@]}" objdump -h "$1" && "${tools[@]}" objdump -s "$1"; } | grep -vF "$1" |
        awk -v label="$LINUX_AGENT_LABEL_SECTION" '/^Contents of section / { skip = ($4 == label ":") } !skip'
}

agent="$tmp/agent.o"
if ! compile "$ROOT/KernovaKit/Sources/CKernovaAgentVersion/CKernovaAgentVersion.c" "$agent"; then
    fail 'CKernovaAgentVersion.c does not compile for aarch64 Linux'
    printf 'linux-agent: %d failed, %d passed\n' "$FAIL" "$PASS" >&2
    exit 1
fi

# ---- the label -------------------------------------------------------------------

compiled=$(objdump_label "$agent")
check_compiled() {
    [ "$compiled" = 'development 64' ] && [ "$(linux_agent_label "$agent")" = development ]
}
if check_compiled; then pass; else
    fail "compiled: objdump reads '$compiled' and linux_agent_label '$(linux_agent_label "$agent")', wanted 'development' in 64 bytes"
fi

# stamped <label> — the object stamped with the label, at $tmp/stamped.o.
stamped() { cp "$agent" "$tmp/stamped.o" && stamp_linux_agent_label "$tmp/stamped.o" "$1"; }
for label in '0.10.0 (2059)' "$(printf 'x%.0s' {1..63})" ''; do
    if ! stamped "$label" 2>"$tmp/err"; then
        fail "stamp '$label': failed: $(cat "$tmp/err")"
    elif [ "$(objdump_label "$tmp/stamped.o")" != "$label 64" ]; then
        fail "stamp '$label': objdump reads '$(objdump_label "$tmp/stamped.o")'"
    elif [ "$(linux_agent_label "$tmp/stamped.o")" != "$label" ]; then
        fail "stamp '$label': linux_agent_label reads '$(linux_agent_label "$tmp/stamped.o")'"
    elif [ "$(other_sections "$tmp/stamped.o")" != "$(other_sections "$agent")" ]; then
        fail "stamp '$label': changed bytes outside the label section"
    elif [ "$(wc -c <"$tmp/stamped.o")" -ne "$(wc -c <"$agent")" ]; then
        fail "stamp '$label': changed the object's size"
    else
        pass
    fi
done

# unchanged <case> <file> <original> — the stamp failed and left the file as it was.
refused() {
    if stamp_linux_agent_label "$2" "$4" 2>/dev/null; then
        fail "$1: the stamp succeeded"
    elif ! cmp -s "$2" "$3"; then
        fail "$1: the failed stamp changed the file"
    else
        pass
    fi
}
cp "$agent" "$tmp/long.o"
refused 'a 64-byte label' "$tmp/long.o" "$agent" "$(printf 'x%.0s' {1..64})"
printf 'not an ELF file\n' >"$tmp/text"
cp "$tmp/text" "$tmp/text.orig"
refused 'a file that is not ELF' "$tmp/text" "$tmp/text.orig" label
printf 'const char *other(void) { return "other"; }\n' >"$tmp/other.c"
compile "$tmp/other.c" "$tmp/other.o" && cp "$tmp/other.o" "$tmp/other.orig"
refused 'an object with no label section' "$tmp/other.o" "$tmp/other.orig" label

# ---- what the agent is built from ------------------------------------------------------

# describe [<dependency type>] [<C's product memberships field>] — a package
# description in the shape `swift package describe --type json` writes:
# kernova-agent is A's, which B and C are in; D is another product's.
describe() {
    local memberships=${2-'"product_memberships": ["kernova-agent"]'}
    cat <<EOF
{
  "dependencies": [{"identity": "swift-protobuf", "type": "${1:-sourceControl}", "url": "https://example.com/p.git"}],
  "products": [
    {"name": "kernova-agent", "targets": ["A"], "type": {"executable": null}},
    {"name": "other", "targets": ["D"], "type": {"executable": null}}
  ],
  "targets": [
    {"name": "A", "path": "Sources/A", "product_memberships": ["kernova-agent"], "target_dependencies": ["B"]},
    {"name": "B", "path": "Sources/B", "product_memberships": ["kernova-agent", "other"], "target_dependencies": ["C"]},
    {"name": "C", "path": "Sources/C"${memberships:+, $memberships}},
    {"name": "D", "path": "Sources/D", "product_memberships": ["other"], "target_dependencies": ["B"]},
    {"name": "T", "path": "Tests/T", "target_dependencies": ["A"], "type": "test"}
  ]
}
EOF
}
sources=$(describe | linux_agent_sources 2>&1)
if [ "$sources" = $'Sources/A\nSources/B\nSources/C' ]; then pass; else
    fail "sources: '$(printf '%s' "$sources" | tr '\n' ' ')', wanted Sources/A Sources/B Sources/C"
fi
sources=$(describe registry | linux_agent_sources 2>&1)
if [ "$sources" = $'Sources/A\nSources/B\nSources/C' ]; then pass; else
    fail "sources: with a registry dependency: '$(printf '%s' "$sources" | tr '\n' ' ')'"
fi
sources=$(describe sourceControl '' | linux_agent_sources 2>&1)
if [ "$sources" = $'Sources/A\nSources/B' ]; then pass; else
    fail "sources: with C in no product: '$(printf '%s' "$sources" | tr '\n' ' ')', wanted Sources/A Sources/B"
fi
# no_sources <case> <description> — linux_agent_sources fails and prints no path.
no_sources() {
    local out
    if out=$(linux_agent_sources <<<"$2" 2>/dev/null); then
        fail "$1: linux_agent_sources succeeded, printing '$(printf '%s' "$out" | tr '\n' ' ')'"
    elif [ -n "$out" ]; then
        fail "$1: linux_agent_sources printed '$out'"
    else
        pass
    fi
}
no_sources 'a local package dependency, which no pin holds' "$(describe fileSystem)"
no_sources 'a description with no product memberships' "$(describe | sed 's/"product_memberships": \[[^]]*\], //; s/, "product_memberships": \[[^]]*\]//')"
no_sources 'a description with no kernova-agent product' "$(describe | sed 's/"kernova-agent", "targets"/"agent", "targets"/')"
no_sources 'a description that is not JSON' 'error: no manifest'

if [ "$FAIL" -gt 0 ]; then
    printf 'linux-agent: %d failed, %d passed\n' "$FAIL" "$PASS" >&2
    exit 1
fi
printf '  %s✓%s linux-agent: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
