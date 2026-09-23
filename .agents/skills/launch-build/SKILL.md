---
name: launch-build
description: Launch the Kernova build just made and confirm the running process is that build, not another copy — every running Kernova, one at the build's own path included, is quit first with the real quit, which save-suspends its VMs. Use whenever a change is verified in the running app, in place of `open` or a double-click.
argument-hint: "[--timeout <seconds>] <binary= path from a build verdict>"
---

Run `.agents/skills/launch-build/launch-build.sh $ARGUMENTS`; its `--help` defines every flag, verdict token, and exit code.
