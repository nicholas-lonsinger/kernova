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
| `com.apple.security.virtualization` | Running guests — compatible with the sandbox on the store: UTM ships exactly this combination there, macOS guests included |
| `com.apple.vm.networking` | Guest networking beyond NAT — vmnet requires it for all API use, and a bridged attachment fails VZ configuration validation without it. Granted by Apple as a managed capability on the App ID; compatible with the sandbox on the store — UTM's store build carries it |
| `com.apple.security.device.audio-input` | Opt-in per-VM microphone passthrough |

`com.apple.vm.networking` is restricted — it must be authorized by the embedded provisioning profile — so the default build signs with `Kernova/Resources/Kernova.Development.entitlements`, the same set minus that key. [BUILD.md](BUILD.md) "Signing identity" owns the selection mechanics and the per-machine opt-in. The sandbox profile needs nothing further: `application.sb` grants the `com.apple.NetworkSharing` mach-lookup exactly when the entitlement is present.

One absence is deliberate:

**`com.apple.security.network.server`.** The app never calls `socket()`/`bind()`/`listen()` — `VZVirtioSocketListener`/`VZVirtioSocketConnection` hand it already-connected fds, and the sandbox's network entitlements gate socket *acquisition*, not I/O on granted fds. The serial relay's `AF_UNIX` listener binds inside the app's own temp directory, which file rules already allow. Neither vsock nor the relay needs it.

The only executable the app spawns is its own bundled `KernovaRelaunchHelper`, sandboxed with `app-sandbox` + `inherit` and nothing else.

## Launch model

Kernova is a resident menu-bar app, with no Mach service anywhere in the design. "Open at Login" is an opt-in General-settings toggle that registers the app itself through `SMAppService.mainApp` (`LoginItemService`), which is MAS- and sandbox-compatible and embeds no helper. A login launch is an ordinary Launch Services open, so the app comes up with its library window like any double-click.

A launch the system performs to service an App Intent carries no open Apple Event at all, so the app comes up headless — `.accessory`, no window, no auto-start pass — and afterwards stays resident or leaves per `AppDelegate.automationIdleOutcome`.
