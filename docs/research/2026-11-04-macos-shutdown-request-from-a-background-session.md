# In a macOS guest, a background session's kAEShutDown logs that user out without asking and leaves the guest running, and a console session's waits for authorization while another user is logged in

**Date:** 2026-11-04 · **Method:** Tester runs on Ephemeral Mode pool VMs, macOS 27.2 (26B123) and macOS 26.7.2, plus checks by hand in the same guests.

The shutdown event was sent with `osascript` from the test user's GUI session (`launchctl asuser 501 sudo -u <user>`), not from the agent. It is the event the session agent sends: `kAEShutDown` to loginwindow (`docs/research/2026-11-03-macos-guest-power-through-agents.md`). The findings quote loginwindow's records in the guest's unified log, and read `/dev/console`'s owner and `who` and `last` in the guest. On macOS 26.7.2 the Fast User Switching login window was reached with `SACSwitchToLoginWindow`.

## Findings

1. **A background session's `kAEShutDown` logs that user out without a prompt, and the guest stays on.** At a Fast User Switching login window:
   - **macOS 27.2:** loginwindow logged `Received a kAEShutDown`, `Calling to start a logout with NO UI` and `TAL Option set directly to: TALRestore`, and quit TextEdit and Finder without a prompt. It then logged `ERROR | session is not on console, set attemptLaunch = NO`, `do not launch sessionlogoutd for this session`, `Failedsessionlogoutdstart` and `LogoutComplete`, and the relaunched loginwindow logged `No users are logged in`.
     - The guest stayed running at the login window for the 90 s sampled, and no `shutdown` process ran.
     - The result was the same with nothing unsaved.
     - When the user logged back in, TextEdit reopened a blank "Untitled" window, though its autosave file still held the text. This is one sample.
   - **macOS 26.7.2:** the log held the same lines, `LogoutComplete` among them, about 1 s after the event, and also `Exiting session is off console, setting exitImmediate = YES`. The guest didn't power off within 60 s. The login window still showed a checkmark beside the user; what it means wasn't checked.
   - In every run the logout completed, and only `sessionlogoutd` was skipped (`attemptLaunch = NO`).
   - **`kAEShowShutdownDialog` (`rsdn`) on 27.2:** the dialog ran its 60 s countdown with nobody seeing it, then the same session-only logout followed. The guest didn't power off.

2. **From the console session, the event stops the guest only while no other user is logged in.** On macOS 26.7.2:
   - **One user logged in:** Kernova showed the VM Stopped at most 12 s after the event. Sent by hand from that session at its lock screen (`/dev/console` owned by that user), the event also powered the guest off each time.
   - **Two users logged in, from the console session at its lock screen** (`/dev/console` owned by that user, by hand):
     - loginwindow logged `showConfirmation:0 … currentTALOption:1 - TALRestore`, then `restart/shutdown, show confirmation reset to YES. FileSharing:0, numberOfUsers:2`, `Option to show confirmation dialog is set`, `set _restartShutdownAuthInProgress to YES` and `logout state: ShutdownAuth`.
     - Two later events logged `_restartShutdownAuthInProgress is YES, ignoring startLogoutRequest`.
     - The guest stayed up, and nobody saw a prompt from these events.
     - A Restart chosen by hand at the login window, with both users logged in, asked for an administrator's name and password.

3. **utmpx's console record outlives the session.** After each of those logouts, `who` and `last` kept listing the user on `console`; in one run the record was still there 7.5 min later. A session ended with `launchctl bootout` left the same record behind.

4. **At the login window, the ACPI shutdown request left the guest running.** With that stale record standing and no user logged in, a Stop routed to no agent (`Power routing ended: untaken(refusals: [])`), so Kernova sent the VM's ACPI shutdown request, and the guest did not shut down. The guest's version was not recorded.

5. **Unsaved work under the Apple menu's commands.** By hand, through Shut Down and Restart in the Apple menu, the "Reopen windows when logging back in" checkbox decided whether unsaved TextEdit work blocked: checked, it didn't block; unchecked, it blocked.
   - Sent by hand at the lock screen with an edited TextEdit document open, `kAEShutDown` powered the guest off with the checkbox both checked and unchecked. Neither the `TAL Option` lines nor the document's fate was recorded.
   - Every Tester run had the checkbox checked.
