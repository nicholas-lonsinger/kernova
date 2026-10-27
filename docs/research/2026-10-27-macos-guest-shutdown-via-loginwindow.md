# A LaunchAgent's `aevtshut` to loginwindow powers off a macOS guest with no dialog

**Date:** 2026-10-27 · **Host:** macOS 27.2 (26B123), Kernova at commit 6f5a3edc · **Guests:** macOS 12.7.6 and 27.2.0, Ephemeral-mode VMs, each auto-logged in as a standard user

## Summary of findings

1. On both guest versions, a per-user LaunchAgent that sends loginwindow the shut-down Apple event (`«event aevtshut»`, [QA1134](https://developer.apple.com/library/archive/qa/qa1134/_index.html)) powered the guest off 6–11 s after the job fired.
2. No dialog appeared on either version: no Automation ("wants access to control") prompt, no loginwindow confirmation, no password prompt.
3. A TextEdit Untitled document holding unsaved text was open throughout, and no save sheet appeared; the guest powered off with it unsaved.
4. Kernova logged "Guest stopped" 26 s after `launchctl bootstrap` on macOS 12.7.6 and 31 s after on macOS 27.2.0 (the job sleeps 20 s first), and showed each VM as Stopped.
5. On macOS 27.2.0 only, writing the plist raised a "Background Activity" notification: "“sh” can run in the background. You can manage background activity in Login Items & Extensions." It did not block the job.
6. `~/Library/LaunchAgents` does not exist on a fresh user account on either version; it had to be created before the plist could be written.

The LaunchDaemon half of #1699 (`shutdown` at the login window) was not run.

## Method

In each guest, from Terminal as the logged-in user:

1. `mkdir -p ~/Library/LaunchAgents`, then write `~/Library/LaunchAgents/app.kernova.probe.power.plist`, a `RunAtLoad` job whose `ProgramArguments` run:

   ```sh
   /bin/sh -c "sleep 20; /usr/bin/osascript -e 'tell application \"loginwindow\" to «event aevtshut»'"
   ```

   `plutil -lint` passed and `plutil -p` showed the arguments as intended.
2. Open TextEdit, type text into the Untitled document, leave it unsaved ("Untitled — Edited").
3. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/app.kernova.probe.power.plist`.
4. Screenshot the guest display at about 10, 25, 40 and 60 s after Return, and read Kernova's log and `kernova list` for the stop.

The job's own output log in the guest's `/tmp` was lost when the Ephemeral VM reverted, so the timing comes from the host side only. The planned save-sheet and `launchctl kickstart` steps did not run: no sheet appeared and the guest had already stopped.
