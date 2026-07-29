# SANDBOX.md

Read this before changing entitlements, signing, app groups, or File Provider IPC — and read it to audit what a Kernova build is permitted to do on the machine running it. The rules for writing new code inside the sandbox are in [AGENTS.md](../AGENTS.md#app-sandbox-rules); the release and notarization flow is in [RELEASING.md](RELEASING.md).

Kernova targets the **Mac App Store** and runs under the **App Sandbox in every build configuration**.

## Entitlement inventory

Everything `Kernova/Resources/Kernova.entitlements` claims:

| Entitlement | Why it is needed |
|---|---|
| `com.apple.security.app-sandbox` | Mac App Store eligibility |
| `com.apple.security.network.client` | Sole network use: macOS restore-image traffic — `IPSWService` downloads and `RestoreImageProbeService`'s ranged probe of a user-supplied URL |
| `com.apple.security.files.user-selected.read-write` | Powerbox grants from open/save panels — disk images, ISOs, shared folders, Linux kernel/initrd, local IPSWs |
| `com.apple.security.files.downloads.read-write` | The fixed IPSW download destination in `~/Downloads` and its `.kernovadownload` resume sidecar |
| `com.apple.security.files.bookmarks.app-scope` | Persisting those panel grants across launches |
| `com.apple.security.virtualization` | Running guests |
| `com.apple.security.device.audio-input` | Opt-in per-VM microphone passthrough |
| `com.apple.security.application-groups` | The staging container the app shares with its File Provider extension; identifier is per-configuration (below) |

Two absences are deliberate:

**`com.apple.security.network.server`.** The app never calls `socket()`/`bind()`/`listen()` — `VZVirtioSocketListener`/`VZVirtioSocketConnection` hand it already-connected fds, and the sandbox's network entitlements gate socket *acquisition*, not I/O on granted fds. The serial relay's `AF_UNIX` listener binds inside the app's own temp directory, which file rules already allow. Neither vsock nor the relay needs it.

**Any entitlement unavailable to Mac App Store apps.** The virtualization entitlement is compatible with the sandbox on the store — UTM ships exactly this combination there, macOS guests included.

The only executable the app spawns is its own bundled `KernovaRelaunchHelper`, sandboxed with `app-sandbox` + `inherit` and nothing else.

## App groups and signing

The group identifier is the per-configuration `KERNOVA_APP_GROUP` build setting. Every executable resolves it at runtime from the `KernovaAppGroup` Info.plist key through KernovaKit's `KernovaAppGroup.identifier()`, because a SwiftPM package cannot read Xcode build settings.

**Debug** uses a Team-ID-prefixed group, `$(DEVELOPMENT_TEAM).app.kernova`. macOS grants silent container access to a group whose prefix matches the signing team (macOS 15 app-group protection, criterion C), so Debug needs no provisioning profile and no portal or device registration — which is what lets anyone build against their own team, and what keeps the guest agent from hitting the "access data from other apps" consent prompt inside an unregistered guest VM.

**Profile-less Debug signing depends on that Team-ID prefix match.** `DEVELOPMENT_TEAM` itself is derived per developer ([BUILD.md](BUILD.md)).

**Release** uses the canonical iOS-style `group.app.kernova` — the form Apple recommends on macOS and the only form developer-portal registration accepts — authorized by an embedded provisioning profile.

Release signing then splits by target.

The **host app** and **host File Provider** sign `Automatic`/Apple Development at build time, with `REGISTER_APP_GROUPS = YES` so Xcode's automatic signing generates profiles carrying the app group, and pick up their Developer ID signature at Organizer export.

The **guest agent** (`KernovaMacOSAgent`) and its **File Provider extension** instead sign **Manual**, with a `Developer ID Application` identity, manually-created Developer ID profiles carrying the `group.app.kernova` authorization, and `OTHER_CODE_SIGN_FLAGS = --timestamp`.

Two constraints force that. The agent is packaged into `Resources/KernovaMacOSAgent.dmg` at *build* time and Xcode's export-time Developer ID re-signing cannot reach inside a DMG resource, so the agent must already carry its final distribution signature when the DMG is baked. And a Developer ID profile is not device-locked, so the agent and its extension validate inside an unregistered guest VM — a *Development* profile would be refused launch outright by `fileproviderd` at device validation, before any app-group check.

## Launch model

Kernova is an ordinary resident menu-bar app — not a launchd agent, and there is no Mach service anywhere in the design. "Open at Login" is an opt-in General-settings toggle over `SMAppService.mainApp` (`LoginItemService`).

Host↔extension IPC is the canonical `NSFileProviderServicing` anonymous-XPC pattern, with no broker: the owner enters through `NSFileProviderManager.getService(named:for:)` and exports the relay, the extension calls back at `fetchContents`, and a Darwin notification is the reconnect doorbell. Both `SMAppService.mainApp` and this pattern are MAS- and sandbox-compatible.

**The domain host must hold the root URL's security scope open for as long as the domain is up.** A sandboxed app has no other access to `~/Library/CloudStorage`, and two things depend on that live scope: the placeholder-creating readdir, and the pasteboard server's sandbox validation of the vended `public.file-url` — pboard mints the pasting app's extension from our live access, and without it the entry is silently rejected and Finder ⌘V just beeps.
