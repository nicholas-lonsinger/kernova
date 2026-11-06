# In a macOS guest, kAEShutDown powers off only from the console session with no other user logged in: from a background session it logs that user out and the guest stays on, and it always reopens apps' windows at the next login

**Date:** 2026-11-04 · **Method:** Tester runs on Ephemeral Mode pool VMs, macOS 27.2 (26B123) and macOS 26.7.2, on one clone of the 27.2 pool VM with Ephemeral Mode off, and checks by hand in the same guests.

The event is the one the session agent sends: `kAEShutDown` to loginwindow (`docs/research/2026-11-03-macos-guest-power-through-agents.md`). Except where a finding says it went through Kernova's Stop, it was sent with `osascript` from the test user's GUI session (`launchctl asuser 501 sudo -u <user>`), not from the agent. The findings quote loginwindow's records in the guest's unified log. They also read `/dev/console`'s owner, and `who` and `last`, in the guest. On macOS 26.7.2 the Fast User Switching login window was reached with `SACSwitchToLoginWindow`.

## Findings

1. **A background session's `kAEShutDown` logs that user out without a prompt, and the guest stays on.** These runs were at a Fast User Switching login window.
   - **macOS 27.2:** loginwindow logged `Received a kAEShutDown`, `Calling to start a logout with NO UI` and `TAL Option set directly to: TALRestore`.
     - It quit TextEdit and Finder without a prompt.
     - It then logged `ERROR | session is not on console, set attemptLaunch = NO`, `do not launch sessionlogoutd for this session`, `Failedsessionlogoutdstart` and `LogoutComplete`.
     - The relaunched loginwindow logged `No users are logged in`.
     - The guest stayed running at the login window for the 90 s sampled, and no `shutdown` process ran.
     - The result was the same with nothing unsaved.
     - When the user logged back in, TextEdit reopened a blank "Untitled" window, though its autosave file still held the text. This is one sample.
   - **macOS 26.7.2:** the log held the same lines, `LogoutComplete` among them, about 1 s after the event.
     - It also held `Exiting session is off console, setting exitImmediate = YES`.
     - The guest didn't power off within 60 s.
     - The login window still showed a checkmark beside the user. What the checkmark means wasn't checked.
   - In every run the logout completed. Only `sessionlogoutd` was skipped (`attemptLaunch = NO`).
   - **`kAEShowShutdownDialog` (`rsdn`) on 27.2:** the dialog ran its 60 s countdown with nobody seeing it, then the same session-only logout followed. The guest didn't power off.

2. **From the console session, the event stops the guest only while no other user is logged in.** All of these ran on macOS 26.7.2.
   - **One user logged in:** Kernova showed the VM Stopped at most 12 s after the event. By hand, from that session at its lock screen (`/dev/console` owned by that user), the event also powered the guest off each time.
   - **Two users logged in, sent by hand from the console session at its lock screen** (`/dev/console` owned by that user):
     - loginwindow logged `showConfirmation:0 … currentTALOption:1 - TALRestore`, then `restart/shutdown, show confirmation reset to YES. FileSharing:0, numberOfUsers:2`.
     - It went on to log `Option to show confirmation dialog is set`, `set _restartShutdownAuthInProgress to YES` and `logout state: ShutdownAuth`.
     - Two later events logged `_restartShutdownAuthInProgress is YES, ignoring startLogoutRequest`.
     - The guest stayed up, and nobody saw a prompt from these events.
     - A Restart chosen by hand from the lock screen's power menu asked for an administrator's name and password. Nothing Kernova or the events sent started that prompt.

3. **The event always takes loginwindow's reopen path, whatever the "Reopen windows when logging back in" setting.** These ran on macOS 27.2.
   - **Setting off.**
     - The `defaults -currentHost` read-back gave `0`, and the Shut Down… dialog's checkbox showed unchecked.
     - In the same boot, the Shut Down… dialog ran with `currentTALOption:0 - TALUseUserPref` and `preserve state enabled 0`.
     - Kernova's Stop ran with `currentTALOption:1 - TALRestore` and `TAL Option set directly to: TALRestore`.
     - TextEdit, holding an unsaved document, quit without asking (`_setShouldRestoreStateOnNextLaunch: shouldRestore=1`).
     - The guest powered off about 10 s after the request.
   - **The user's last confirmed choice.** This ran on the clone, with the agent "For everyone", through Kernova's Stop.
     - The Restart… dialog applies the saved choice: `TALUseUserPref`, then `using saved pref, set talOption to: TALNoRestore` with the box unchecked, or `TALRestore` with it checked.
     - Every Stop logged `currentTALOption:1 - TALRestore` and `TAL Option set directly to: TALRestore`, whichever choice was last confirmed.
     - The Stop left the remembered choice unchanged.
     - TextEdit quit without asking each time, and the guest powered off 8–10.5 s after the request.
     - At the next start, TextEdit reopened by itself with each unsaved document's title and text. This held whether the last confirmed choice was unchecked or checked.
     - `defaults -currentHost read com.apple.loginwindow TALLogoutSavesState` found no domain at any point, so the dialog's choice isn't stored under that key.
   - **By hand, through the Apple menu's Shut Down and Restart,** the checkbox decided whether unsaved TextEdit work blocked them: checked, it didn't; unchecked, it did.
   - **By hand, at the lock screen,** `kAEShutDown` powered the guest off with an edited TextEdit document open, with the checkbox both checked and unchecked.

4. **An app holding the request shows its own prompt, then loginwindow's alert, and the sender is told nothing.** This ran on macOS 27.2, through Kernova's Stop, with Terminal running `ping`.
   - Terminal's sheet appeared within about 1 s: "Do you want to terminate running processes in this window?"
   - At 45 s, loginwindow showed "Your Mac hasn't shut down because "Terminal" failed to quit. To continue shutting down, quit "Terminal"." with Cancel and Try Again, and logged `com.apple.logoutInterrupted`.
   - Kernova's power lines ended at `tookIt` and `handedOff`, and Kernova showed nothing.
   - Clicking Terminate let the shutdown go on, and the guest powered off 14.8 s later.

5. **utmpx's console record outlives the session.** After each logout in finding 1, `who` and `last` kept listing the user on `console`; in one run the record was still there 7.5 min later. A session ended with `launchctl bootout` left the same record behind.

6. **At the login window, the ACPI shutdown request left the guest running.** With that stale record standing and no user logged in, a Stop routed to no agent (`Power routing ended: untaken(refusals: [])`). So Kernova sent the VM's ACPI shutdown request, and the guest did not shut down. The guest's version was not recorded.
