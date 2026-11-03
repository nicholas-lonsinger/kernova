# In a macOS guest, loginwindow takes an agent's kAEShutDown with no prompt and says nothing of an app's cancel, and shutdown(8) at the login window powers off before its caller can report

**Date:** 2026-11-03 · **Method:** a live run on Ephemeral Mode pool VMs, macOS 12.7.6 and macOS 27.2, from Kernova Debug `0.10.0 (1173)` on branch `feat/macos-agent-power` (PR #1814).

Every guest command ran over SSH. The guest's records were streamed with `/usr/bin/log stream --level info --predicate 'subsystem BEGINSWITH "app.kernova"'` and the host's read with `/usr/bin/log show`, each to a file per step, beside screenshots and a once-a-second `kernova list` sample of the VM's state. Timestamps are each log's own clock.

The agent on the disk was signed ad hoc with the hardened runtime and the Apple Events entitlement:

```
[Key] com.apple.security.automation.apple-events  [Value] [Bool] true
[Key] com.apple.security.get-task-allow           [Value] [Bool] true
CodeDirectory v=20500 size=47767 flags=0x10002(adhoc,runtime) hashes=1482+7 location=embedded
Signature=adhoc
```

The session agent sends loginwindow `kAEShutDown` (`kCoreEventClass`, target bundle id `com.apple.loginwindow`) with `.noReply` while its session owns the console. The system service runs `/sbin/shutdown -h now` as root while the login window is up.

## Findings

1. **R1: the session agent's `kAEShutDown` at the console** (agent installed "Just for me", pbear's desktop up, nothing else running).
   - Neither version showed an Automation prompt or any other dialog, and the guest powered off.
   - The send returned `noErr` 0.002 s after the agent logged the ask, and loginwindow quit the agent with reason `73687574` (`'shut'`) 0.25–0.47 s later:

     | | `Asking macOS to shut down` | `macOS answered the power request: tookIt` | `Asked to quit, reason 73687574` | `Shutting down, exit status 75` |
     |---|---|---|---|---|
     | 12.7.6 | 10:07:14.863 | 10:07:14.865 | 10:07:15.111 | 10:07:15.112 |
     | 27.2 | 10:10:55.141 | 10:10:55.143 | 10:10:55.609 | 10:10:55.609 |

   - The host logged `Power routing ended: handedOff`, then `Guest stopped` 1.7 s (12.7.6) and 1.9 s (27.2) after `Routing shut down across the guest's agents`.

2. **R2: an app that cancels the shutdown** (as R1, with `sleep 9999` running in a Terminal window).
   - Both versions showed Terminal's prompt, "Do you want to terminate running processes in this window?" / "Closing this window will terminate the running process sleep.", with Cancel and Terminate.
   - After Cancel, the guest showed "“Terminal” interrupted shut down." / "To continue shutting down, quit “Terminal”.", with Cancel and Try Again.
   - The agent logged `tookIt` and nothing after it: loginwindow never quit it. Its pid was the same before the Stop and 15 s after the Cancel, and `launchctl print` read `last exit code = (never exited)`.
   - The host logged `Power routing ended: handedOff` at once (27.2: routing at 10:18:11.823, ended 10:18:11.827), showed no alert, and the VM stayed Running.
   - On 27.2, a further Stop while the interrupted dialog was up logged `tookIt` again, and the guest added "Your computer is already shutting down." with OK.

3. **R2b: loginwindow's reply does not wait for the apps** (as R2, the event sent by `osascript` with a reply and a 120 s timeout instead of by the agent: `launchctl asuser <pbear's uid> /usr/bin/osascript -e 'with timeout of 120 seconds' -e 'tell application "loginwindow" to «event aevtshut»' -e 'end timeout'`).
   - On both versions `osascript` exited 0 with no error text, before Terminal's prompt appeared: `osascript exit 0 after 0 s` (27.2) and `after 1 s` (12.7.6). No Automation prompt appeared.
   - So the reply to `kAEShutDown` carries no word of an app's cancel, and a sender that waits for it learns no more than one that sends with `.noReply`.

4. **R3: the system service's `shutdown -h now` at the login window** (agent installed "For everyone", pbear logged out with `sudo defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser` then `sudo launchctl bootout user/<pbear's uid>`, so only the system service was connected).
   - On both versions the guest powered off without a dialog.
   - The guest's log held `Asking macOS to shut down` and nothing after it from the agent: neither `macOS answered the power request: tookIt` nor the agent's own `Shutting down` line.
   - The host read the connection's end before any answer: the request had not been accepted, so routing ended `indeterminate`, and the host showed the alert "Kernova can’t tell whether “macOS 27.2.0” is shutting down. If it doesn’t stop, use Force Stop." The alert stayed up after the VM read Stopped.

     | | Routing begins | `Asking macOS to shut down` (guest) | `Power routing ended: indeterminate` | `The system peer left: closedByPeer(… shuttingDown …)` | `Guest stopped` |
     |---|---|---|---|---|---|
     | 27.2 | 10:35:43.442 | 10:35:43.445 | 10:35:43.696 | 10:35:43.698 | 10:35:45.068 |
     | 12.7.6 | 10:38:17.184 | 10:38:17.176 | 10:38:17.250 | 10:38:17.251 | 10:38:18.532 |

## Evidence

The Tester's run folder for this session holds, by step: `guest-r1-12.log`, `guest-r1-27.log`, `guest-r2-*.log` and `guest-r3-*.log` (the guest streams above); `kernova.log` (the host's records for the whole run); `state-*.txt` (the once-a-second state samples); `r2-*-step3.txt` and `r2-*-step8.txt` (the agent's pid and `launchctl print` before the Stop and after the Cancel); `r2b-12.txt` and `r2b-27.txt` (the `osascript` output); `agent-signature-12.txt`; and `screens/`, among them `r2-27-terminal-prompt.png`, `r2-12-interrupted.png`, `r2-27-second-stop-dialogs.png`, `r2b-12-prompt.png` and `r3-27-alert-now.png`.
