# logind and polkit accept a power-off from a systemd user service; systemd 259 refuses it over the same user's block inhibitor and systemd 255 does not

**Date:** 2026-10-28 · **Host:** a Debug build of Kernova · **Guests:** all three are GNOME on Wayland, Ephemeral-mode VMs auto-logged in as `pbear` (uid 1000):

| Guest | systemd | polkit | Terminal |
|---|---|---|---|
| Ubuntu 26.04.1 LTS | 259 (`259.9-0ubuntu0.1`) | 127 | Ptyxis |
| Fedora Linux 44 Workstation Edition | 259 (`259.10-1.fc44`) | 127 | Ptyxis |
| Ubuntu 24.04.5 LTS | 255 (`255.4-1ubuntu8.18`) | 124 | GNOME Terminal 3.52.0 |

## Summary of findings

All three guests gave the same answers unless a finding names one.

1. **polkit from a user service.** A process in a `systemd-run --user` unit got the same answers as the GNOME terminal. On Ubuntu 26.04 its cgroup was `0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-p2967-i761.service`.
   - `CanPowerOff` and `CanReboot` returned `s "yes"`.
   - `pkcheck` exited 0 for `org.freedesktop.login1.power-off` and `reboot`.
   - `PowerOff(false)` from such a unit powered the guest off. On the systemd 259 guests that was with nothing unsaved; on systemd 255 it was over the block inhibitor of finding 2.
   - `kernova list`, polled each second (every 1–2 s on 24.04), showed Running, then Restoring, then Stopped:

     | Guest | Return | Last Running | Restoring | Stopped |
     |---|---|---|---|---|
     | Ubuntu 26.04 | about 23:23:44 | — | 23:23:49 | 23:23:51 |
     | Fedora 44 | 23:55:51 | — | 23:55:53 | 23:55:54 |
     | Ubuntu 24.04 | about 01:04:29 | 01:04:33.7 | 01:04:34.9 | 01:04:36.0 |
2. **What logind does with a same-user power-off over a block inhibitor depends on the systemd version.** Text Editor held an unsaved draft, and logind listed gnome-session's inhibitor:

   | Guest | Inhibitor | COMM in `systemd-inhibit --list` |
   |---|---|---|
   | Ubuntu 26.04 | `('shutdown', 'pbear', 'user session inhibited', 'block', 1000, 5154)` | `gnome-session-s` |
   | Fedora 44 | the same, with pid 5304 | `gnome-session-s` |
   | Ubuntu 24.04 | the same, with pid 3415 | `gnome-session-b` |

   `PowerOff(false)` was then sent straight to logind with `gdbus`, which bypasses `systemctl`.
   - **systemd 259** (Ubuntu 26.04, Fedora 44): logind refused. The call was made once from a user-service unit and once from the GNOME terminal. Each returned at once with:

     ```text
     Error: GDBus.Error:org.freedesktop.login1.BlockedByInhibitorLock: Operation denied due to active block inhibitor
     ```

     `gdbus` exited 1. No dialog appeared, and `kernova list` showed the VM Running at every poll for at least the next 69 s. Discarding Text Editor's draft removed the inhibitor from logind's list. The next call, from a user-service unit, is the power-off in finding 1.
   - **systemd 255** (Ubuntu 24.04): the first call, from a user-service unit with the draft still unsaved, powered the guest off (finding 1's times). The guest's screenshot 5 s after Return already showed the VM Stopped.
3. **GNOME names the app; logind names gnome-session.** These were read from a user-service unit while the draft was unsaved.
   - `org.gnome.SessionManager.GetInhibitors` on the user bus returned `ao 1 "/org/gnome/SessionManager/Inhibitor1"`. That inhibitor gave:
     - `GetAppId`: `s "org.gnome.TextEditor"`;
     - `GetReason`: `s "There are unsaved documents"`;
     - `GetFlags`: `u 1`.
   - `/usr/share/applications/org.gnome.TextEditor.desktop` has `Name=Text Editor`.
   - logind's `ListInhibitors` held no entry naming Text Editor. Its shutdown block was finding 2's: uid 1000, who `pbear`, why `user session inhibited`.
   - On the systemd 259 guests, `GetInhibitors` returned `ao 0` after the discard.
4. **Session reads.**
   - `GetSessionByPID(0)` returned `Call failed: Caller does not belong to any known session.` for every caller:
     - the GNOME terminal's shell. Its cgroup was `…/user@1000.service/app.slice/ptyxis-spawn-<uuid>.scope` under Ptyxis, and `…/user@1000.service/app.slice/app-org.gnome.Terminal.slice/vte-spawn-<uuid>.scope` under GNOME Terminal;
     - the user-service unit;
     - the system-account units.
   - From the user-service unit:
     - `/org/freedesktop/login1/user/self` and `/org/freedesktop/login1/user/_1000` both returned `Display` `(so) "1" "/org/freedesktop/login1/session/_31"` and `Name` `s "pbear"`.
     - `/org/freedesktop/login1/session/self` failed: `Unknown object '/org/freedesktop/login1/session/self'.`
     - `/org/freedesktop/login1/session/auto` returned `Id` `s "1"`.
   - The `Display` session read:

     | Property | Value |
     |---|---|
     | `Id` | `s "1"` |
     | `Active` | `b true` |
     | `State` | `s "active"` |
     | `Class` | `s "user"` |
     | `Type` | `s "wayland"` |
     | `Seat` | `(so) "seat0" "/org/freedesktop/login1/seat/seat0"` |
   - While the user was logged in, the user-service unit and the system account both read seat0's `ActiveSession` as `(so) "1" "/org/freedesktop/login1/session/_31"`, with `Class` `s "user"`.
5. **At the login screen seat0's active session has class `greeter`.** A system-account unit sampled seat0's `ActiveSession` every 5 s through a logout.
   - It read session `1`, class `user`, until GDM's session took over, then class `s "greeter"`:

     | Guest | GDM's session | From |
     |---|---|---|
     | Ubuntu 26.04 | `(so) "c1" "/org/freedesktop/login1/session/c1"` | 23:02:52 |
     | Fedora 44 | `"c2"` | 23:45:09 |
     | Ubuntu 24.04 | `"c1"` | 00:55:38 |
   - No sample showed an empty `ActiveSession`.
   - `loginctl list-sessions` then listed only GDM's sessions. On Ubuntu 26.04:

     ```text
      3 60578 gdm-greeter -     3677 manager-early -    no -
     c1 60578 gdm-greeter seat0 3605 greeter       tty1 no -
     ```

     On Ubuntu 24.04:

     ```text
     c1 120 gdm seat0 tty1 active no -
     ```

6. **A system account's verdict, with and without a polkit rule.** On Ubuntu 24.04 these lines were transcribed from a full-resolution screenshot, not copied.
   - **Without the rule,** the system account `kernova-probe` got `CanPowerOff` and `CanReboot` `s "challenge"`, and `pkcheck` exited 2:
     - polkit 127: `polkit\56result=auth_admin_keep polkit\56retains_authorization_after_challenge=1 Authorization requires authentication and -u wasn't passed.`
     - polkit 124: `polkit\56retains_authorization_after_challenge=1 Authorization requires authentication and -u wasn't passed.`
   - **With the rule,** which returns YES for that account on `power-off`, `power-off-multiple-sessions`, `reboot` and `reboot-multiple-sessions`, `pkcheck` exited 0 on every guest. polkit 127 printed `polkit\56result=yes`; polkit 124 printed nothing.
   - `CanPowerOff` with the rule differed by guest:
     - **Fedora 44 and Ubuntu 24.04:** `s "yes"`, both in the reads taken 3 s after the rule was written and in every later sample.
     - **Ubuntu 26.04:** `s "challenge"` in those reads, which also had `pkcheck` print `polkit\56result=yes`. The sampler's first read, at 23:02:11, was also `s "challenge"`. Every read from 23:02:16 on, including those at the login screen, was `s "yes"`. The script had started at 23:02:08.

## Method

Every command reached the guest as host clipboard text pasted into the terminal with Ctrl+Shift+V. The probe script went in as a quoted heredoc in six parts of at most 1,000 bytes, and the guest's `sha256sum` of the written file matched the source. Output was read back over the guest-to-host clipboard, or transcribed from a screenshot.

Every D-Bus call below goes to `org.freedesktop.login1` on the system bus unless it names the user bus. The Can\* and property reads used `busctl`. The power-off and `ListInhibitors` calls used `gdbus`, which prints the error name and sends no allow-interactive-authorization flag. These were the callers:

- **T:** the GNOME terminal.
- **S:** `systemd-run --user --wait --pipe` units.
- **N, then R:** `sudo systemd-run --uid=kernova-probe --wait --pipe` units, run as a system account made with `useradd --system --no-create-home`.
- **The sampler:** a long-running `systemd-run --uid=kernova-probe` unit.

In each guest:

1. **Reads as the user,** by T and S:
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
   - N made the same Can\*, `pkcheck`, `GetSessionByPID` and seat0 reads, as `kernova-probe`.
   - Then `/etc/polkit-1/rules.d/50-kernova-probe.rules` was written. It returns `polkit.Result.YES` for `subject.user == "kernova-probe"` on the four actions in finding 6. After 3 s, R repeated N's reads.
   - Then the sampler started. Every 5 s it read seat0's `ActiveSession`, that session's `Class`, and `CanPowerOff`. After three consecutive `greeter` samples it stopped sampling, ran the Can\* and `pkcheck` reads, and ran `loginctl list-sessions --no-legend`.
3. **Logout:** `gnome-session-quit --logout --no-prompt`. No dialog appeared, and GDM's login screen showed. The guest stayed at the login screen for 2 minutes, then the user logged back in.
4. **Inhibitor views:** Text Editor was opened, text was typed, and the document was left unsaved; its title showed `• kernova probe unsaved` and its subtitle `Draft`. Then an S unit ran:
   - `systemd-inhibit --list`;
   - `ListInhibitors`;
   - `busctl --user call org.gnome.SessionManager /org/gnome/SessionManager org.gnome.SessionManager GetInhibitors`, then `GetAppId`, `GetReason` and `GetFlags` on each inhibitor;
   - a lookup of `<app id>.desktop` under `~/.local/share`, `/usr/local/share`, `/usr/share` and `/var/lib/flatpak/exports/share`.
5. **Power-off ladder.** The ladder stopped at the first call that powered the guest off. Each call was `gdbus call --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 --method org.freedesktop.login1.Manager.PowerOff false`. During each call, the guest was screenshotted at about 5, 15 and 30 s, and `kernova list` was polled.
   1. From an S unit, with the draft unsaved. On Ubuntu 24.04 this call powered the guest off, and the ladder ended.
   2. From the terminal, with the draft unsaved.
   3. In Text Editor's "Save Changes?" dialog (buttons Cancel, Discard and Save), Discard was pressed, and step 4's inhibitor views were read again.
   4. From an S unit again.
