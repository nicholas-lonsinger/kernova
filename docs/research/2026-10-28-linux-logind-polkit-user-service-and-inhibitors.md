# logind and polkit accept a power-off from a systemd user service and refuse it over the same user's block inhibitor

**Date:** 2026-10-28 · **Host:** a Debug build of Kernova · **Guests:** Ubuntu 26.04.1 LTS (systemd 259, `259.9-0ubuntu0.1`; polkit 127) and Fedora Linux 44 Workstation Edition (systemd 259, `259.10-1.fc44`; polkit 127), both GNOME on Wayland, Ephemeral-mode VMs auto-logged in as `pbear` (uid 1000)

## Summary of findings

Both guests gave the same answers unless a finding names one.

1. **polkit from a user service.** A process in a `systemd-run --user` unit (cgroup `0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-p2967-i761.service` on Ubuntu) got the same answers as the GNOME terminal: `CanPowerOff` and `CanReboot` returned `s "yes"`, and `pkcheck` exited 0 for `org.freedesktop.login1.power-off` and `reboot`. With nothing unsaved, `PowerOff(false)` from such a unit powered the guest off. `kernova list`, polled each second, showed Running, then Restoring, then Stopped:
   - Ubuntu: Return at about 23:23:44, Restoring at 23:23:49, Stopped at 23:23:51.
   - Fedora: Return at 23:55:51, Restoring at 23:55:53, Stopped at 23:55:54.
2. **logind refuses a same-user power-off over a block inhibitor.** Text Editor held an unsaved draft. With it open, logind listed gnome-session's inhibitor as `('shutdown', 'pbear', 'user session inhibited', 'block', 1000, 5154)`; on Fedora the pid was 5304. `PowerOff(false)` was sent to logind with `gdbus`, which bypasses `systemctl`. It was sent once from a user-service unit and once from the GNOME terminal, and each call returned at once with:

   ```text
   Error: GDBus.Error:org.freedesktop.login1.BlockedByInhibitorLock: Operation denied due to active block inhibitor
   ```

   `gdbus` exited 1. No dialog appeared, and `kernova list` showed the VM Running at every poll for the next 69 s or more. After Text Editor's draft was discarded, that inhibitor was gone from logind's list. The power-off in finding 1 is the next call, made from a user-service unit.
3. **GNOME names the app; logind names gnome-session.** These are read from a user-service unit while the draft was unsaved.
   - `org.gnome.SessionManager.GetInhibitors` on the user bus returned `ao 1 "/org/gnome/SessionManager/Inhibitor1"`. That inhibitor gave:
     - `GetAppId`: `s "org.gnome.TextEditor"`;
     - `GetReason`: `s "There are unsaved documents"`;
     - `GetFlags`: `u 1`.
   - `/usr/share/applications/org.gnome.TextEditor.desktop` has `Name=Text Editor`.
   - logind's `ListInhibitors` held no entry naming Text Editor. The shutdown block was held by uid 1000 with who `pbear` and why `user session inhibited`; `systemd-inhibit --list` shows its COMM as `gnome-session-s`.
   - After the discard, `GetInhibitors` returned `ao 0`.
4. **Session reads.**
   - `GetSessionByPID(0)` returned `Call failed: Caller does not belong to any known session.` for every caller:
     - the GNOME terminal's shell, whose cgroup is `…/user@1000.service/app.slice/ptyxis-spawn-<uuid>.scope`;
     - the user-service unit;
     - the system-account units.
   - From the user-service unit:
     - `/org/freedesktop/login1/user/self` and `/org/freedesktop/login1/user/_1000` both returned `Display` `(so) "1" "/org/freedesktop/login1/session/_31"` and `Name` `s "pbear"`.
     - `/org/freedesktop/login1/session/self` failed: `Unknown object '/org/freedesktop/login1/session/self'.`
     - `/org/freedesktop/login1/session/auto` returned `Id` `s "1"`.
   - The `Display` session read `Id` `s "1"`, `Active` `b true`, `State` `s "active"`, `Class` `s "user"`, `Type` `s "wayland"` and `Seat` `(so) "seat0" "/org/freedesktop/login1/seat/seat0"`.
   - While the user was logged in, seat0's `ActiveSession` was `(so) "1" "/org/freedesktop/login1/session/_31"`, with `Class` `s "user"`. The user-service unit and the system account read the same values.
5. **At the login screen seat0's active session has class `greeter`.** A system-account unit sampled seat0's `ActiveSession` every 5 s through a logout.
   - It read session `1`, class `user`, until GDM's session took over: `(so) "c1" "/org/freedesktop/login1/session/c1"` on Ubuntu from 23:02:52, and `"c2"` on Fedora from 23:45:09, each with class `s "greeter"`.
   - No sample showed an empty `ActiveSession`.
   - `loginctl list-sessions` then listed only GDM's sessions. On Ubuntu:

     ```text
      3 60578 gdm-greeter -     3677 manager-early -    no -
     c1 60578 gdm-greeter seat0 3605 greeter       tty1 no -
     ```

6. **A system account's verdict, with and without a polkit rule.**
   - Without the rule, the system account `kernova-probe` got `CanPowerOff` and `CanReboot` `s "challenge"`, and `pkcheck` exit 2: `polkit\56result=auth_admin_keep polkit\56retains_authorization_after_challenge=1 Authorization requires authentication and -u wasn't passed.`
   - The rule returns YES for that account on `power-off`, `power-off-multiple-sessions`, `reboot` and `reboot-multiple-sessions`. With it, `pkcheck` exited 0 with `polkit\56result=yes` on both guests.
   - `CanPowerOff` differed by guest:
     - **Fedora:** `s "yes"` in the reads taken 3 s after the rule was written, and in every later sample.
     - **Ubuntu:** `s "challenge"` in those reads, which also returned `pkcheck` `polkit\56result=yes`. The sampler's first read, at 23:02:11, was also `s "challenge"`; every read from 23:02:16 on, including those at the login screen, was `s "yes"`. The script had started at 23:02:08.

No guest with a systemd older than 257 was available, so the Ubuntu 24.04 (systemd 255) behavior is unobserved.

## Method

Every command went into the guest as host clipboard text pasted into Ptyxis with Ctrl+Shift+V. The probe script went in as a quoted heredoc in six parts of at most 1,000 bytes. The guest's `sha256sum` of the written file matched the source. Output was read back over the guest-to-host clipboard, or transcribed from a screenshot.

Every D-Bus call below is to `org.freedesktop.login1` on the system bus unless it names the user bus. The Can\* and property reads used `busctl`. The power-off and `ListInhibitors` calls used `gdbus`, which prints the error name and sends no allow-interactive-authorization flag. These were the callers:

- the GNOME terminal (T);
- `systemd-run --user --wait --pipe` units (S);
- `sudo systemd-run --uid=kernova-probe --wait --pipe` units, under a system account made with `useradd --system --no-create-home` (N, then R);
- a long-running `systemd-run --uid=kernova-probe` unit (the sampler).

In each guest:

1. **Reads as the user** (T and S):
   - `CanPowerOff` and `CanReboot`;
   - `pkcheck --action-id org.freedesktop.login1.power-off --process $$`, and the same for `reboot`;
   - `GetSessionByPID u 0`;
   - `/proc/self/cgroup`.

   S also read:
   - `User.Display` and `User.Name` on `/org/freedesktop/login1/user/self` and `user/_1000`;
   - `Session.Id` on `session/self` and `session/auto`;
   - the `Display` session's `Id`, `Name`, `Active`, `State`, `Class`, `Type` and `Seat`;
   - seat0's `ActiveSession` and that session's `Class`.
2. **Reads as a system account:**
   - The same Can\*, `pkcheck`, `GetSessionByPID` and seat0 reads, as `kernova-probe` (N).
   - Then `/etc/polkit-1/rules.d/50-kernova-probe.rules` was written, returning `polkit.Result.YES` for `subject.user == "kernova-probe"` on the four actions in finding 6. After 3 s the reads were repeated (R).
   - Then the sampler started. Every 5 s it read seat0's `ActiveSession`, that session's `Class`, and `CanPowerOff`. It stopped after three consecutive `greeter` samples, then ran the Can\* and `pkcheck` reads (G) and `loginctl list-sessions --no-legend`.
3. **Logout:** `gnome-session-quit --logout --no-prompt`. No dialog appeared and GDM's login screen showed. The guest stayed there for 2 minutes, then the user logged back in.
4. **Inhibitor views:** open Text Editor, type text, and leave it unsaved; the title showed `• kernova probe unsaved` and the subtitle `Draft`. Then, from an S unit:
   - `systemd-inhibit --list`;
   - `ListInhibitors`;
   - `busctl --user call org.gnome.SessionManager /org/gnome/SessionManager org.gnome.SessionManager GetInhibitors`, then `GetAppId`, `GetReason` and `GetFlags` on each inhibitor;
   - a lookup of `<app id>.desktop` under `~/.local/share`, `/usr/local/share`, `/usr/share` and `/var/lib/flatpak/exports/share`.
5. **Power-off ladder,** stopping at the first call that powered the guest off. Each call was `gdbus call --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 --method org.freedesktop.login1.Manager.PowerOff false`. During each, the guest was screenshotted at about 5, 15 and 30 s, and `kernova list` was polled every second.
   1. From an S unit, with the draft unsaved.
   2. From the terminal, with the draft unsaved.
   3. In Text Editor's "Save Changes?" dialog, press Discard (its buttons were Cancel, Discard and Save). Repeat step 4's inhibitor views.
   4. From an S unit again.
