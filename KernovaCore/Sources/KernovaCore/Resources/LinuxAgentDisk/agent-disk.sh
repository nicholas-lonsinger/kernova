#!/bin/sh
# The Kernova guest agent disk's install.sh and uninstall.sh: one script under
# both names, which runs `kernova-agent install` or `kernova-agent uninstall` by
# the name it was run as.
#
#   sh install.sh [--system]     the agent for the user who runs it; with
#                                --system, the system service too
#   sh uninstall.sh [--system]   removes the same
#
# kernova-agent does the work. This copies it off the disk, which Kernova
# ejects once an agent it bundles connects, and runs it from the copy. The
# --system step is the one that runs as root: sudo asks for it here, and a
# root shell runs it, and only it, without sudo.

set -eu

main() {
    script=${0##*/}
    case "$script" in
        install.sh) verb=install ;;
        uninstall.sh) verb=uninstall ;;
        *) echo "run this as sh install.sh or sh uninstall.sh, not as $script" >&2; exit 64 ;;
    esac
    system=''
    case "$*" in
        '') ;;
        --system) system=yes ;;
        *) echo "usage: sh $script [--system]" >&2; exit 64 ;;
    esac

    machine=$(uname -m)
    if [ "$machine" != aarch64 ]; then
        echo "$script: the Kernova guest agent runs on 64-bit Arm (aarch64) Linux, not $machine" >&2
        exit 1
    fi

    if [ "$(id -u)" -eq 0 ]; then
        if [ -z "$system" ]; then
            echo "$script: as root, only --system applies; run it as the user the agent is for without it" >&2
            exit 64
        fi
    elif [ -n "$system" ] && ! command -v sudo >/dev/null 2>&1; then
        echo "$script: --system needs sudo, which this system lacks; run sh $script --system as root" >&2
        exit 1
    fi

    disk=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    staged=$(mktemp -d)
    trap 'rm -rf "$staged"' EXIT
    cp "$disk/kernova-agent" "$staged/kernova-agent"
    chmod 0755 "$staged/kernova-agent"

    if [ "$(id -u)" -eq 0 ]; then
        "$staged/kernova-agent" "$verb" --system
    else
        "$staged/kernova-agent" "$verb"
        if [ -n "$system" ]; then
            sudo "$staged/kernova-agent" "$verb" --system
        fi
    fi
}

# On one line, so sh has read all of it before the disk can go away.
main "$@"; exit
