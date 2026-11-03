# In a macOS guest with a user logged in, shutdown(8) run as root powers off without asking any app, and an unsaved TextEdit document comes back through autosave

**Date:** 2026-11-03 · **Method:** a live run on two clones of pool VMs, macOS 27.2 and macOS 12.7.6, from Kernova Debug built from commit `7ecd5953` (branch `feat/macos-agent-power`, PR #1814).

Each clone was an exact copy of its pool VM (`kernova clone <id> --id --exact-copy`) with Ephemeral Mode turned off (`kernova set <id> --id ephemeral=false`), so the guest's disk kept what the shutdown left at the next start. Guest commands ran over SSH as `pbear`, whose `sudo` asks no password. A once-a-second `kernova list` sample recorded the VM's state, beside screenshots.

The guest was at `pbear`'s desktop, with:
- TextEdit holding a new rich-text document with typed words, never saved, its window titled "Untitled — Edited";
- Terminal running `sleep 9999` in its window, which `pgrep -lf 'sleep 9999'` found.

The command was `ssh <address> 'sudo -n /sbin/shutdown -h now'`. No Kernova agent took part: this is the call the system service makes.

## Findings

1. **No app was asked anything.** On both versions the guest showed no dialog between the command and power-off: no TextEdit save sheet, no Terminal "terminate running processes" prompt, and no "interrupted shut down" alert.

2. **The guest powered off.** From the command to the VM reading Stopped:

   | | Command | First Stopped sample | Seconds |
   |---|---|---|---|
   | 27.2 | 13:01:32 | 13:01:39 | about 7 |
   | 12.7.6 | 13:05:34 | 13:05:37 | about 3 |

3. **Terminal's process ended** with the guest.

4. **At the next start, TextEdit's unsaved document came back through autosave.**
   - 27.2: no app reopened by itself at login. After `open -a TextEdit` the window "Untitled — Edited" showed the words typed before the shutdown ("Hello from four").
   - 12.7.6: TextEdit and Terminal relaunched by themselves at login, TextEdit's window "Untitled — Edited" holding the words typed before the shutdown ("Hello from twelve"), and Terminal's a new `zsh` window.

## Evidence

The Tester's run folder for this session holds `r4-27-t0.txt` and `r4-12-t0.txt` (the command's host time), `state-r4-27.txt` and `state-r4-12.txt` (the once-a-second state samples), and in `screens/`: `r4-27-textedit-before-shutdown.jpg`, `r4-27-before-shutdown.png`, `r4-27-poll/` (the guest between the command and power-off), `r4-27-after-start-noapps.png`, `r4-27-textedit-restored.png`; `r4-12-textedit-words.jpg`, `r4-12-terminal-sleep.jpg`, `r4-12-before-shutdown.png`, `r4-12-poll/`, `r4-12-after-start.png` and `r4-12-after-start-restored.jpg`.
