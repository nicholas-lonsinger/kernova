# LIVE-VERIFICATION.md

Read this before checking a change in the running app, against a guest or through App Intents.

## Launching the build

Quit any other running Kernova first: a launch goes to a running instance of the app, whichever copy's path was opened, and the old binary keeps answering.

## Against a guest

Take an offered agent update before observing anything: what an older agent does is not what the build does.

Keystrokes a screen-control tool sends into a VM's display can reach the guest as other characters, or not at all, while the tool reports success, so read the guest screen back before pressing Return. Move anything longer than a short answer by clipboard: with the VM's **Clipboard sharing** on, the Clipboard window's **Paste from Mac** takes in the host pasteboard and offers it to the guest, where ⌘V pastes it.

## App Intents

Spotlight and Siri see Kernova's intents only from a build installed in `/Applications` and launched once. A build running from DerivedData shows only its app row in Spotlight while Shortcuts still lists and runs every intent, which reads like broken intent metadata. `ditto` the build to `/Applications/Kernova.app`, confirm no other on-disk copy outranks it, and launch that copy.

Start the log stream before acting, over `process == "Kernova" OR process == "linkd" OR process == "searchtoold" OR process == "assistantd"`. The framework's `com.apple.appintents:Execution` lines are debug-level, so `log show` afterwards never has them, and a narrower capture cannot tell whether a request reached Kernova.

To run an intent without the Shortcuts editor, write a `WFWorkflowActions` plist whose action identifier is `app.kernova.<IntentTypeName>` and whose parameters are keyed by property name. A file parameter bound to Shortcut Input is `{"Value":{"Type":"ExtensionInput"},"WFSerializationType":"WFTextTokenAttachment"}`. Convert the plist with `plutil -convert binary1`, since `shortcuts sign` rejects XML, then run `shortcuts sign --mode anyone --input <plist> --output <name>.shortcut`.

`open` the signed file and choose Add Shortcut; the shortcut takes the file's name, and `shortcuts run <name> -i <path>` runs it. The first run that hands Kernova a file raises Shortcuts' approval to share that file with Kernova — the proof the file bound to the parameter — and the maintainer answers it.
