# SANDBOX.md

Read this before changing entitlements — and read it to audit what a Kernova build is permitted to do on the machine running it. The rules for writing new code inside the sandbox are in [AGENTS.md](../AGENTS.md#app-sandbox-rules); signing and the release flow are in [RELEASING.md](RELEASING.md).

Kernova targets the **Mac App Store** and runs under the **App Sandbox in every build configuration**.

## Entitlement inventory

Everything `Kernova/Resources/Kernova.entitlements` claims:

| Entitlement | Why it is needed |
|---|---|
| `com.apple.security.app-sandbox` | Mac App Store eligibility |
| `com.apple.security.network.client` | Sole network use: guest-image traffic — `DownloadService` streams macOS restore images and Linux installer ISOs, `LinuxImageResolveService` fetches checksum manifests, and `RemoteFileSizeProbe` sizes both kinds before any download |
| `com.apple.security.files.user-selected.read-write` | Powerbox grants from open/save panels — disk images, ISOs, shared folders, Linux kernel/initrd, local IPSWs |
| `com.apple.security.files.downloads.read-write` | The fixed download destination in `~/Downloads` — macOS restore images and Linux installer ISOs — and their `.kernovadownload` resume sidecars |
| `com.apple.security.files.bookmarks.app-scope` | Persisting those panel grants across launches |
| `com.apple.security.virtualization` | Running guests |
| `com.apple.security.device.audio-input` | Opt-in per-VM microphone passthrough |

Two absences are deliberate:

**`com.apple.security.network.server`.** The app never calls `socket()`/`bind()`/`listen()` — `VZVirtioSocketListener`/`VZVirtioSocketConnection` hand it already-connected fds, and the sandbox's network entitlements gate socket *acquisition*, not I/O on granted fds. The serial relay's `AF_UNIX` listener binds inside the app's own temp directory, which file rules already allow. Neither vsock nor the relay needs it.

**Any entitlement unavailable to Mac App Store apps.** The virtualization entitlement is compatible with the sandbox on the store — UTM ships exactly this combination there, macOS guests included. `com.apple.vm.networking` (bridged networking) is *not* in this category, despite being widely assumed Developer ID-only: Apple grants it on request for App Store distribution too — UTM's store build carries it. It is absent because nothing creates bridged network devices, not for eligibility.

The only executable the app spawns is its own bundled `KernovaRelaunchHelper`, sandboxed with `app-sandbox` + `inherit` and nothing else.

## Launch model

Kernova is a resident menu-bar app, with no Mach service anywhere in the design. "Open at Login" is an opt-in General-settings toggle that registers the app itself through `SMAppService.mainApp` (`LoginItemService`), which is MAS- and sandbox-compatible and embeds no helper. A login launch is an ordinary Launch Services open, so the app comes up with its library window like any double-click.
