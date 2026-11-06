# LIVE-VERIFICATION.md

Read this before checking a change in the running app, against a guest or through App Intents.

## Launching the build

Drive a build with the `kernova` tool inside it, `Kernova.app/Contents/Helpers/kernova`: each copy of Kernova answers only the tool in its own bundle, and the one on `PATH` links into whichever copy installed it. An `open`, by path or by bundle identifier, starts a new instance beside a running copy, and every copy loads the same VM library.
Every other copy running on the Mac, the maintainer's or another session's, is one more process named Kernova, so a window or process query selects the copy under test by its PID (`kCGWindowOwnerPID` for a window), never by owner or process name.
A running copy you did not launch belongs to the maintainer or another session, so ask before quitting it. Quit your own with its tool's `kernova quit`: ⌘Q only closes its windows while it keeps running in the menu bar.

## Against a guest

Take an offered agent update before observing anything: what an older agent does is not what the build does.

Keystrokes a screen-control tool sends into a VM's display can reach the guest as other characters, or not at all, while the tool reports success, so read the guest screen back before pressing Return. Move anything longer than a short answer by clipboard: with the VM's **Clipboard sharing** on, **Edit → Copy Mac Clipboard to Guest** copies the host pasteboard to the guest's clipboard, where ⌘V pastes it.

The guest agent installs with no prompt to answer, by SSH or a pasted line, once Virtual Machine ▸ Install Guest Agent… has mounted its disk:

- macOS: `NONINTERACTIVE=1 bash "/Volumes/Kernova Guest Agent/install.command"` installs it just for the user; `--system` installs it for everyone. `NONINTERACTIVE` makes its sudo `sudo -n`, so for everyone the guest needs passwordless sudo.
- Linux: `findmnt -n LABEL=KERNOVA_AGENT >/dev/null || udisksctl mount -b /dev/disk/by-label/KERNOVA_AGENT >/dev/null; NONINTERACTIVE=1 sh "$(findmnt -nro TARGET LABEL=KERNOVA_AGENT)/install.sh" --system`. `NONINTERACTIVE` makes its sudo `sudo -n`, so the guest needs passwordless sudo.

A run reaches past a guest's login screen without its password by setting the guest up first, in a guest it may change:

- GNOME: `sudo groupadd -f nopasswdlogin; sudo usermod -aG nopasswdlogin <user>`, and `auth sufficient pam_succeed_if.so user ingroup nopasswdlogin` at the top of `/etc/pam.d/gdm-password`; one click on the user's row then logs in. `AutomaticLoginEnable=false` in GDM's `custom.conf` keeps a boot at the login screen. To log out: `sudo -u <user> DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u <user>)/bus gnome-session-quit --logout --no-prompt`.
- macOS with automatic login: keep a copy of `/etc/kcpassword` and the `autoLoginUser` value from `/Library/Preferences/com.apple.loginwindow`. Deleting both turns automatic login off, and restoring both then `sudo killall loginwindow` logs in. To log out: `sudo launchctl bootout user/$(id -u <user>)`.

## App Intents

Spotlight and Siri see Kernova's intents only from a build installed in `/Applications` and launched once. A build running from DerivedData shows only its app row in Spotlight while Shortcuts still lists and runs every intent, which reads like broken intent metadata. `ditto` the build to `/Applications/Kernova.app`, confirm no other on-disk copy outranks it, and launch that copy.

When the check is done, quit that copy with its own `kernova quit`, unregister it with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Applications/Kernova.app`, and delete it with `rm -rf`, then confirm with `make ghosts` that no `/Applications` copy remains. Not the Trash: a bundle there stays registered and can win the election until the Trash is emptied.

Start the log stream before acting, over `processIdentifier == <that copy's PID> OR process == "linkd" OR process == "searchtoold" OR process == "assistantd"`. The framework's `com.apple.appintents:Execution` lines are debug-level, so `log show` afterwards never has them, and a narrower capture cannot tell whether a request reached Kernova.

To run an intent without the Shortcuts editor, write a `WFWorkflowActions` plist whose action identifier is `app.kernova.<IntentTypeName>` and whose parameters are keyed by property name. A file parameter bound to Shortcut Input is `{"Value":{"Type":"ExtensionInput"},"WFSerializationType":"WFTextTokenAttachment"}`. Convert the plist with `plutil -convert binary1 -o <name>-unsigned.shortcut <plist>`, since `shortcuts sign` rejects XML and refuses an input whose name does not end in `.shortcut`, then run `shortcuts sign --mode anyone --input <name>-unsigned.shortcut --output <name>.shortcut`.

An entity parameter — a virtual machine, a network — is bound in the Shortcuts editor instead: build the shortcut there, adding the action by searching for its title.

`open` the signed file and choose Add Shortcut; the shortcut takes the file's name, and `shortcuts run <name> -i <path>` runs it. Its first run raises Shortcuts' approval for the shortcut to access Kernova, and the first run that hands Kernova a file raises the approval to share that file with Kernova — the proof the file bound to the parameter. The maintainer answers both, so arrange the run with them.
