# A Linux guest powers off without a prompt from its session and from a polkit-granted system service

**Date:** 2026-10-27 · **Host:** Kernova at commit 6f5a3edc · **Guests:** Ubuntu Desktop 26.04 and Fedora Workstation 44 (GNOME), Ephemeral-mode VMs, each auto-logged in as the user `pbear`

## Summary of findings

1. From the logged-in session, without sudo, `systemctl poweroff` powered each guest off in about 6 s, with no authentication dialog.
2. From the session, without sudo, `systemctl reboot` while Text Editor held unsaved work was refused at once: no save prompt, no authentication dialog, no reboot. Ubuntu's terminal printed:

   ```text
   Operation inhibited by "pbear" (PID 1559 "gnome-session-s", user pbear), reason is "user session inhibited".
   Please retry operation after closing inhibitors and logging out other users.
   'systemd-inhibit' can be used to list active inhibitors.
   Alternatively, ignore inhibitors and users with 'systemctl reboot -i'.
   ```

   Fedora printed the same message, from PID 1347.
3. A transient unit running as a system account granted `org.freedesktop.login1.power-off`, `power-off-multiple-sessions`, `reboot` and `reboot-multiple-sessions` by a polkit rule ran `systemctl poweroff` at the GDM login screen, and both guests powered off with no prompt: Ubuntu at 16:44:43, Fedora at 16:58:22.
4. On Ubuntu's first attempt the same unit fired at 16:26:26, while the logout was still in progress (the login screen first appeared at 16:26:28–34). The journal recorded `Call to PowerOff failed: Operation denied due to active block inhibitor` and the unit exited with status 1. There was no polkit denial line; the rule grants no `power-off-ignore-inhibit`.

Debian was not tested: no Debian VM was available. The other-user-logged-in and headless cases from #1698 were not run.

## Method

In each guest:

1. **Session poweroff.** In Terminal as `pbear`, run `systemctl poweroff`; screenshot the guest at about 5, 15 and 30 s and poll `kernova list` for the stop.
2. **Session reboot with unsaved work.** Start the VM again, open Text Editor and type text into an unsaved document, then run `systemctl reboot` in Terminal; screenshot at about 5, 15, 30 and 60 s.
3. **System service at the login screen.** With sudo, create a system account `kernova-probe` and `/etc/polkit-1/rules.d/50-kernova-probe.rules`, which returns YES for that user on the four `org.freedesktop.login1` actions above. Then schedule

   ```sh
   systemd-run --uid=kernova-probe --on-active=90 $(command -v systemctl) poweroff
   ```

   and log out with `gnome-session-quit --logout --no-prompt`. Read the result from Kernova's state and the guest journal.

Typing "/" does not reach these guests, so the timer line used `$(command -v systemctl)` for the path. On the first Ubuntu attempt `gnome-session-quit --logout --no-prompt` still showed GNOME's 60-second logout dialog. The timers fired 96–150 s after scheduling, consistent with systemd's default one-minute timer accuracy.
