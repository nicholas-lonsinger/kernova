# LIVE-VERIFICATION.md

Read this before checking a change in the running app, against a guest or through App Intents.

## Launching the build

Each copy of Kernova answers only the `kernova` tool in its own bundle, which can start that copy; the tool on `PATH` links into whichever copy installed it.
`open` by path starts the named build beside any copy already running, and every copy loads the same VM library. A bundle identifier names no one build: `open -b app.kernova` starts whichever registered copy Launch Services picks, which has been another session's.

Every copy on the Mac is a process named Kernova, so only a PID tells the copy under test from the maintainer's or another session's in a window or process query.
A running copy you did not launch is the maintainer's or another session's, with their work in it. ⌘Q closes a copy's windows and leaves it running in the menu bar; `kernova quit` ends it.

## Against a guest

Take an offered agent update before observing anything: what an older agent does is not what the build does.

With the VM's **Clipboard sharing** on, **Edit → Copy Mac Clipboard to Guest** puts the Mac's clipboard on the guest's.

The agent's installers ask nothing under `NONINTERACTIVE=1`; `KernovaMacOSAgent/install.command`'s header and the Linux disk's `README.txt` give the lines.

A guest's login screen can be passed without its password, in a guest the run may change:

- GNOME logs a member of the `nopasswdlogin` group in on one click of their row once `/etc/pam.d/gdm-password` opens with `auth sufficient pam_succeed_if.so user ingroup nopasswdlogin`.
- A macOS guest with automatic login stays at the login screen once `/etc/kcpassword` and `autoLoginUser` in `/Library/Preferences/com.apple.loginwindow` are gone, and logs in when both are back and `loginwindow` is killed.

## App Intents

Spotlight, Siri and Shortcuts see Kernova's intents from a build installed in `/Applications` and launched once. With only a DerivedData build running, Shortcuts has listed no Kernova actions, which reads like broken intent metadata.

`/Applications/Kernova.app`, where it exists, is the maintainer's installed copy, and installing a build there replaces it: theirs to allow. `make ghosts` reports an on-disk copy that outranks the installed one.

Afterwards, unregister the copy you installed with `lsregister -u` and delete it outright: a bundle in the Trash stays registered and can win the election until the Trash is emptied.

A log capture that can tell whether a request reached Kernova is a stream started before acting, over the copy's PID, `linkd`, `searchtoold` and `assistantd` ([research note](research/2026-09-04-siri-and-spotlight-routing-macos27-beta.md)). The framework's `com.apple.appintents:Execution` lines are mostly info-level, so `log show` afterwards has them only with `--info`.

An intent runs without the Shortcuts editor from a signed shortcut file: a `WFWorkflowActions` plist whose action identifier is `app.kernova.<IntentTypeName>` and whose parameters are keyed by property name. `shortcuts sign` takes only a file whose name ends in `.shortcut`, and signing checks nothing in its actions.

An entity parameter — a virtual machine, a network — binds only in the Shortcuts editor, where the action is found by its title.

`open` the signed file and choose Add Shortcut; the shortcut takes the file's name.
