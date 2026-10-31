#!/bin/sh
# The Kernova guest agent disk's install.sh and uninstall.sh: one script under
# both names, which runs `kernova-agent install` or `kernova-agent uninstall` by
# the name it was run as.
#
#   sh install.sh [--system]     the agent for the user who runs it; with
#                                --system, the system service too
#   sh uninstall.sh [--system]   removes the same
#
# It prints what the chosen scope will change, from kernova-agent's own dry run
# of the steps it then takes, and waits for Return. With NONINTERACTIVE set to
# anything but empty it skips the wait and runs sudo -n, which fails at once
# where sudo would ask for a password.
#
# kernova-agent does the work. This copies it off the disk, which Kernova
# ejects once an agent it bundles connects, and runs it from the copy. The
# --system step is the one that runs as root: sudo runs it here, printed first,
# and a root shell runs it, and only it, without sudo.

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
    sudo=sudo
    if [ -n "${NONINTERACTIVE:-}" ]; then sudo='sudo -n'; fi

    machine=$(uname -m)
    if [ "$machine" != aarch64 ]; then
        echo "$script: the Kernova guest agent runs on 64-bit Arm (aarch64) Linux, not $machine" >&2
        exit 1
    fi

    root=''
    if [ "$(id -u)" -eq 0 ]; then
        root=yes
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
    agent=$staged/kernova-agent

    # The plan: each scope's own dry run, as a user, of the steps it then takes.
    if [ -z "$root" ]; then "$agent" "$verb" --dry-run; fi
    if [ -n "$system" ]; then "$agent" "$verb" --system --dry-run; fi
    if [ -z "${NONINTERACTIVE:-}" ]; then
        printf 'Press Return to continue, or Control-C to cancel. '
        if ! read -r _; then
            echo
            echo "$script: no answer, so nothing was changed" >&2
            exit 1
        fi
    fi

    if [ -n "$root" ]; then
        "$agent" "$verb" --system
        return
    fi
    if [ -n "$system" ]; then
        # sudo's answer first, so a refused sudo stops before anything changes.
        # A command, not -v: -v asks for a password unless every sudoers entry
        # for the user is NOPASSWD, where a command needs only the one it
        # matches.
        echo "+ $sudo true"
        if ! $sudo true; then
            echo "$script: sudo refused, so nothing was changed" >&2
            exit 1
        fi
    fi
    "$agent" "$verb"
    if [ -n "$system" ]; then
        echo "+ $sudo $agent $verb --system"
        $sudo "$agent" "$verb" --system
    fi
}

# On one line, so sh has read all of it before the disk can go away.
main "$@"; exit
