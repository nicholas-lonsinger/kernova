# What a built Linux guest agent must be before Kernova bundles it. Sourced,
# never run, by the script that builds it and the one that compares two
# builds.

# shellcheck shell=bash

# The most bytes a built agent may hold: about a third over its size, room for
# what later features add, and ICU's locale data alone would take it past.
LINUX_AGENT_BUDGET=$((16 * 1024 * 1024))

# check_linux_agent <binary>: whether the binary is the agent Kernova can
# bundle — a statically linked aarch64 ELF within the budget, carrying no ICU
# data — reporting on stderr each way it is not. ICU arrives with Foundation's
# internationalization API, such as a date formatter with a locale, and not
# with the import alone; its locale data's table of contents names every item
# `icudt<version>…`. The binary is stripped, so its bytes are read rather than
# its symbols.
check_linux_agent() {
    local binary=$1 description size icu failed=0
    description="$(file -b "$binary")"
    case "$description" in
        *"ELF 64-bit LSB"*"ARM aarch64"*"statically linked"*) ;;
        *) echo "error: $binary is not a static aarch64 ELF: $description" >&2; failed=1 ;;
    esac
    size="$(wc -c <"$binary" | tr -d '[:space:]')"
    if [ "$size" -gt "$LINUX_AGENT_BUDGET" ]; then
        echo "error: $binary is $size bytes, over the $LINUX_AGENT_BUDGET-byte budget" >&2
        failed=1
    fi
    icu="$(LC_ALL=C grep -ac icudt "$binary" || true)"
    if [ "$icu" -ne 0 ]; then
        echo "error: $binary carries ICU data ($icu lines name icudt)" >&2
        failed=1
    fi
    return "$failed"
}
