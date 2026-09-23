# LIVE-VERIFICATION.md

Read this before checking a change in the running app, against a guest or through App Intents.

## Launching the build

Drive a build with the `kernova` tool inside it, `Kernova.app/Contents/Helpers/kernova`: each copy of Kernova answers only the tool in its own bundle, and the one on `PATH` links into whichever copy installed it. An `open`, by path or by bundle identifier, starts a new instance beside a running copy, and every copy loads the same VM library.
A running copy you did not launch belongs to the maintainer or another session, so ask before quitting it. Quit your own with its tool's `kernova quit`: ⌘Q only closes its windows while it keeps running in the menu bar.

## Against a guest

Take an offered agent update before observing anything: what an older agent does is not what the build does.

Keystrokes a screen-control tool sends into a VM's display can reach the guest as other characters, or not at all, while the tool reports success, so read the guest screen back before pressing Return. Move anything longer than a short answer by clipboard: with the VM's **Clipboard sharing** on, the Clipboard window's **Paste from Mac** takes in the host pasteboard and offers it to the guest, where ⌘V pastes it.

## App Intents

Spotlight and Siri see Kernova's intents only from a build installed in `/Applications` and launched once. A build running from DerivedData shows only its app row in Spotlight while Shortcuts still lists and runs every intent, which reads like broken intent metadata. `ditto` the build to `/Applications/Kernova.app`, confirm no other on-disk copy outranks it, and launch that copy.

Start the log stream before acting, over `process == "Kernova" OR process == "linkd" OR process == "searchtoold" OR process == "assistantd"`. The framework's `com.apple.appintents:Execution` lines are debug-level, so `log show` afterwards never has them, and a narrower capture cannot tell whether a request reached Kernova.

To run an intent without the Shortcuts editor, write a `WFWorkflowActions` plist whose action identifier is `app.kernova.<IntentTypeName>` and whose parameters are keyed by property name. A file parameter bound to Shortcut Input is `{"Value":{"Type":"ExtensionInput"},"WFSerializationType":"WFTextTokenAttachment"}`. Convert the plist with `plutil -convert binary1`, since `shortcuts sign` rejects XML, then run `shortcuts sign --mode anyone --input <plist> --output <name>.shortcut`.

`open` the signed file and choose Add Shortcut; the shortcut takes the file's name, and `shortcuts run <name> -i <path>` runs it. The first run that hands Kernova a file raises Shortcuts' approval to share that file with Kernova — the proof the file bound to the parameter — and the maintainer answers it.
