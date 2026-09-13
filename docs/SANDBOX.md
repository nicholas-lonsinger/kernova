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
| `com.apple.developer.accessory-access.usb` | Passing a host USB accessory through to a guest. The sandbox profile keys on it directly — `frameworks.sb` grants the `AppleUSBHostDeviceUserClient`/`AppleUSBHostFrameworkDeviceClient` IOKit user clients to a process holding it. Public and App Store-eligible in Xcode's capability catalog as *Claim USB Accessory*, so enabling it on the App ID needs no request to Apple |
| `com.apple.security.application-groups` | The container the app and the bundled `kernova` tool meet in, holding the command socket. `$(TeamIdentifierPrefix)` is load-bearing, so an ad-hoc build resolves no group and offers no socket ([research note](research/2026-09-05-cli-transport-launchd-domains-and-sandboxed-sockets.md)) |

Two of these are **restricted** — they must be authorized by the embedded provisioning profile, and amfid kills an ad-hoc-signed binary claiming one at exec (`AppleMobileFileIntegrityError` −424, *"The file is adhoc signed but contains restricted entitlements"*):

- `com.apple.vm.networking`, granted by Apple as a managed capability on the App ID.
- `com.apple.developer.accessory-access.usb`, enabled on the App ID from Xcode's capability catalog without asking Apple.

So the default build signs with `Kernova/Resources/Kernova.Development.entitlements`, the same set minus both, and `Tools/check-entitlements.sh` holds the two files to exactly that difference. A profile-less checkout therefore offers neither bridged networking nor USB accessory passthrough — both degrade by absence through `EntitlementService`, which is also why a machine opting into the full set needs *Claim USB Accessory* enabled on the App ID before it will build. [BUILD.md](BUILD.md) "Signing identity" owns the selection mechanics and the per-machine opt-in.

The sandbox profile needs nothing further for either: `application.sb` grants the `com.apple.NetworkSharing` mach-lookup exactly when `com.apple.vm.networking` is present, and `frameworks.sb` grants the USB host user clients exactly when `com.apple.developer.accessory-access.usb` is.

One absence is deliberate:

**`com.apple.security.network.server`.** It gates network-family listeners, which the app has none of. `VZVirtioSocketListener`/`VZVirtioSocketConnection` hand it already-connected fds, and the sandbox's network entitlements gate socket *acquisition*, not I/O on granted fds. Both `AF_UNIX` listeners are admitted by file rules on where they bind: the serial relay's inside the app's own temp directory, the command socket's inside the app-group container ([research/2026-09-05-cli-transport-launchd-domains-and-sandboxed-sockets.md](research/2026-09-05-cli-transport-launchd-domains-and-sandboxed-sockets.md) — both ends of that exchange hold neither `network.client` nor `.server`).

The only executable the app spawns is its own bundled `KernovaRelaunchHelper`, sandboxed with `app-sandbox` + `inherit` and nothing else.

## Launch model

Kernova is a resident menu-bar app, with no Mach service anywhere in the design. "Open at Login" is an opt-in General-settings toggle that registers the app itself through `SMAppService.mainApp` (`LoginItemService`), which is MAS- and sandbox-compatible and embeds no helper.

What a launch puts on screen is decided in one place, `AppResidencyController.launchPosture`, from two things the sandbox bears on: whether the launch came up hidden, and whether it came from the login item. Two things ask for a hidden launch — the system servicing an App Intent, and the bundled `kernova` tool, whose launch options are what the sandbox constrains (`AppLaunch.launchEnclosingApp`).

The process then stays until somebody quits it; `AppTerminationController` owns what that does.
