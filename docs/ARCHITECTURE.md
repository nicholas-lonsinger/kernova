# Architecture

## Overview

Read this before a structural change — a new service or protocol, a changed data flow, a changed
actor isolation. It records what exists and how the pieces connect; what a component *does* is
owned by its own doc comment.

Kernova manages virtual machines through Apple's Virtualization.framework, with macOS and Linux
guests. Pure AppKit (no `import SwiftUI` in the app target), macOS 26, Swift 6 strict concurrency,
no non-Apple dependencies.

Clipboard rules are in [CLIPBOARD.md](CLIPBOARD.md), sandbox/signing/launch model in
[SANDBOX.md](SANDBOX.md), toolbar construction in [TOOLBAR.md](TOOLBAR.md).

## Component Map

### App Layer

- `AppDelegate` — the entry point. Creates `VMLibraryViewModel` and `VMLifecycleCoordinator`, owns
  the application menu, and tracks window controllers in dictionaries keyed by VM UUID, so one VM
  can have a detail pane, a display window, and a clipboard window open at once.
- `HostAgentStatusItemController` — the menu-bar status item. Kernova runs as a resident
  `.accessory` app whose VMs keep running with no window open, so this is the only affordance while
  headless; under XCTest (`isTestHost`) the same binary is instead a plain foreground test host.
- `MainWindowController` — the library window: a `SnapToFitSplitViewController` holding the
  `SidebarViewController` source list and `DetailContainerViewController`, plus an `NSToolbar`.
- `VMToolbarManager` — the toolbar items shared between the library window and the pop-out display
  window; window-specific items stay with their own controller.
- `VMDisplayWindowController`, `ClipboardWindowController` — per VM, created and tracked by
  `AppDelegate`. `SettingsWindowController` is an app-level singleton.

Lifecycle commands surface on the menu bar, the sidebar context menu, and the toolbar, and all
three take their titles from `VMInstance` display helpers (`startAction`, `stopActionMenuTitle`,
`stopActionToolbarLabel`) rather than spelling their own — no surface can name an action
differently. Advanced actions (Start in Recovery Mode, Force Stop) are always visible in the menu
bar and Option-revealed in the sidebar, gated by `AppPreferences.alwaysShowAdvancedOptions`.

### Models

- `VMConfiguration` — a VM's persisted identity: a `Codable` `Sendable` struct written as
  `config.json` inside the VM bundle.
- `VMInstance` — a VM's runtime representation: an `@Observable` `@MainActor` class wrapping a
  `VMConfiguration`, an optional `VZVirtualMachine`, and a `VMStatus`. It owns the per-VM vsock
  listeners, `clipboardService`, `SerialSocketRelay`, and `runtimeFileAccess`. View-layer helpers
  live in the `VMInstance+Display.swift` extension.
- `VMBundleLayout` — a `Sendable` struct deriving every in-bundle path (disk image, aux storage,
  save file, serial log) from the bundle root; the one place path logic lives.
- `VMStatus`, `VMBootMode`, `VMGuestOS`, `MacOSInstallState` — enums.

**Storage topology mirrors VZ.** `VMConfiguration.storageDisks` maps onto `vzConfig.storageDevices`
and `removableMedia` onto `usbControllers[0].usbDevices`. Removable media is hot-pluggable; storage
disks are deliberately *not* live-editable, because VZ requires that device list fixed at start
time. Physical sizes are read from the files at display time and never stored — they change out of
band.

**Device UUIDs are persisted, never regenerated per launch.** `restoreMachineStateFrom(url:)`
matches `VZUSBDeviceConfiguration.uuid` against the saved-state file's recorded device list, so
`RemovableMediaItem.id` is written to `config.json` and reused as the device UUID, and the
synthesized main disk derives its own from the bundle path
(`ConfigurationBuilder.stableMainDiskID(forBundleAt:)`). Fresh UUIDs break restore.
`clonedForNewInstance` regenerates them so two bundles never share device identity.

### Services

The services the view models inject conform to a protocol in `Services/Protocols/` so tests can
substitute mocks. Services split by concurrency: those that touch
`VZVirtualMachine` are `@MainActor`; stateless ones are `Sendable` structs.

`@MainActor`:

- `VirtualizationService` — start, stop, pause, resume, save and restore VM state.
- `MacOSInstallService` — restore-image load, platform-file creation, and the `VZMacOSInstaller`
  run with KVO progress.
- `USBDeviceService` — runtime USB mass-storage attach/detach against the live XHCI controller.
  Owned by `VMLifecycleCoordinator`.
- `SystemSleepWatcher` — `NSWorkspace` sleep/wake observer owned by `VMLibraryViewModel`, which
  auto-pauses running VMs before sleep and resumes them on wake.

`Sendable` structs:

- `VMStorageService` — creates, lists, clones and deletes VM bundles under
  `~/Library/Application Support/Kernova/VMs/`. Deletion has two dispositions, `deleteVMBundle`
  (Trash) and `permanentlyDeleteVMBundle` (the user-confirmed bypass).
- `DiskImageService` — creates ASIF disk images by decompressing bundled templates in-process.
- `IPSWService` (a `final class`, for `URLSession` lifetime) — resolves the latest supported restore
  image through VZ and streams IPSW downloads into a resumable `.kernovadownload` bundle.
- `RestoreImageCatalogService` — decodes the bundled snapshot of selectable macOS restore images,
  `Kernova/Resources/RestoreImageCatalog.json`, backing the wizard's "Choose a Version…" source. It
  reaches no network; only the image the user picks is fetched, by `IPSWService`.
- `LocalRestoreImageInspector` — reads a restore image already on disk through `VZMacOSRestoreImage`,
  which loads from a file URL, so the version, build and supported-configuration verdict are the
  framework's own. Consulted before the wizard adopts a file it did not download itself.
- `RestoreImageProbeService` (a `final class`, for `URLSession` lifetime) — establishes that a
  user-supplied URL serves an installable restore image, and how large it is, before any download.
  An IPSW is a zip whose central directory names `kernelcache.release.vma2` exactly when the image
  carries the virtual-machine hardware model, so ranged reads of the directory settle it in about
  150 KB. `Tools/regen-restore-image-catalog.swift` applies the same check to every catalog
  candidate, which is what puts a pasted URL on the same footing as a catalog row.

`ConfigurationBuilder` translates a `VMConfiguration` into a `VZVirtualMachineConfiguration` — the
single VZ-facing translation point, covering boot loader, CPU, memory, storage, network, display,
input, audio, the Linux SPICE console port, and the macOS `VZVirtioSocketDeviceConfiguration`.

**VZ is only ever handed symlink-resolved URLs.** VZ resolves no symlinks and rejects a path
containing one in any component, reporting it as a missing or invalid file while `FileManager`
reports the file present and readable. `ConfigurationBuilder` and `MacOSInstallService` resolve
through `PathValidation` before every hand-off. This is not defensive: under the sandbox
`.downloadsDirectory` is the container's `Downloads`, itself a symlink to the real one.

The vsock stack (macOS guests only):

- `VsockPorts` — the port registry. Each service
  gets its own listener instead of in-band multiplexing; `KernovaMacOSAgent/VsockPorts.swift`
  mirrors the same assignments guest-side.
- `VsockListenerHost` — one `VZVirtioSocketListener` per port, bridging an accepted connection to a
  `VsockChannel`. Its `shouldAdmit` predicate refuses a connection before any channel is built;
  `VMInstance` wires the log and clipboard listeners to `admitsFeatureChannel`, so no feature
  channel is accepted before the control handshake completes. Socket-buffer sizing and its
  measurements: [research/2026-07-13-vsock-transport-throughput.md](research/2026-07-13-vsock-transport-throughput.md).
- `VsockControlService` — `@MainActor` `@Observable` owner of the always-on control channel:
  `Hello`/`Heartbeat` exchange, a liveness watchdog, the observed `agentVersion`, and `PolicyUpdate`
  pushes carrying an `AgentPolicySnapshot` (built by a closure that reads the current
  configuration, so a reconnect picks up live toggles). Installed for every macOS guest with a
  socket device, independent of clipboard sharing.
- `VsockGuestLogService` — forwards guest `LogRecord` frames into the `app.kernova.guest` subsystem.

The log and clipboard listeners are gated on their configuration toggles and re-evaluated at
runtime through `VMInstance.applyLivePolicy(oldConfig:newConfig:)`. Linux clipboard sharing is
restart-only — its SPICE port must be declared at config-build time.

Clipboard (principles and trade-off rules: [CLIPBOARD.md](CLIPBOARD.md)):

- `ClipboardServicing` — the `@MainActor` protocol both transports implement.
  `VMInstance.clipboardService` holds the existential, so the window controllers never branch on
  transport. Agent install/version state lives on `VsockControlService`,
  which runs whether or not clipboard sharing is enabled.
- `SpiceClipboardService` — the Linux transport, over raw `VZFileHandleSerialPortAttachment` pipes
  parsed by `SpiceAgentParser`. Text only. It uses raw pipes rather than
  `VZSpiceAgentPortAttachment` so clipboard data flows through the gated UI instead of the host
  `NSPasteboard`.
- `VsockClipboardService` — the macOS transport, over `VsockChannel`, driving `KernovaKit`'s
  `ClipboardStreamSender`/`ClipboardStreamReceiver`. Offers are metadata-only; bytes stream on
  request.
- `HostClipboardPublisher`, `ClipboardPassthroughCoordinator` — host-side publication of inbound
  guest content, and the auto-publish path.
- `HostClipboardFileProvider` — app-level singleton, not per VM: the Mac has one pasteboard and one
  File Provider manifest, so the domain is owned once. Backs the host extension under Helper
  Targets.
- `AgentStatus` — the enum driving install/update/reinstall affordances, sourced from
  `VsockControlService` (macOS) or `SpiceClipboardService` (Linux) and read through
  `VMInstance.agentStatus`.
- `KernovaMacOSAgentInfo` — accessors for the bundled agent's version and installer DMG. The
  version comes from a build-phase-written sidecar so it cannot drift from the shipped binary
  ([BUILD.md](BUILD.md)).

Also here: `LoginItemService` (the `SMAppService.mainApp` wrapper behind the Open at Login toggle),
`AttachmentFileMonitor` (existence watching for the settings attachment rows), `RuntimeFileAccess`
(per-boot security-scoped access, released once in `tearDownSession`), and `SerialSocketRelay`
(below).

**Configuration writes have one door.** Every write — settings controls, install/uninstall flows,
rename, and guest-driven `VMInstance.onUpdateConfiguration` callbacks — routes through
`VMLibraryViewModel.updateConfiguration(of:mutate:)`, which persists and then calls
`applyLivePolicy`. No control writes `instance.configuration` directly.
`VMConfiguration.liveEditableFieldsChanged(old:new:)` is the single source of truth for whether a
change takes effect while the VM runs.

**Removable-media reconcile.** `applyLivePolicy` drops media changes into a coalescing drain that
calls `applyLiveRemovableMediaChange(for:target:)`.

### ViewModels

- `VMLibraryViewModel` — the central `@Observable` view model. Owns `[VMInstance]` and every
  list-level operation, persists order and selection through an injected `AppPreferences`,
  delegates lifecycle work to `VMLifecycleCoordinator`, and drives alerts, sheets and the wizard by
  calling its `VMLibraryPresenting` delegate imperatively rather than toggling observed flags.
  Clone and import register a preparing "phantom" `VMInstance` **synchronously, before any
  `await`** — that is what reserves the destination atomically on the MainActor, so overlapping
  imports and clones cannot claim the same bundle URL.
- `VMLifecycleCoordinator` — `@MainActor`; owns `VirtualizationService`, `MacOSInstallService`,
  `IPSWService`, `USBDeviceService` and the `FileSystemOperating` seam, and orchestrates multi-step
  flows such as a macOS install. It serializes lifecycle operations per VM; `stop` and `forceStop`
  deliberately bypass that serialization so a hung operation can always be cancelled.
- `VMCreationViewModel` — a pure `@Observable` state machine for the creation wizard, with no
  UI-framework dependency. Injects `RestoreImageCatalogProviding` for the version picker and
  `RestoreImageProbing` for the paste-a-URL sheet.
- `VMDirectoryWatcher` — a `DispatchSource` on the VMs directory that triggers reconciliation in
  `VMLibraryViewModel` when the library changes on disk.

### Views

Pure AppKit throughout: `NSViewController`/`NSView` subclasses plus free `make*` atom factories,
observing `VMLibraryViewModel` and individual `VMInstance`s through the Observation framework —
usually the `observeRecurring` seam below, occasionally a hand-rolled `withObservationTracking`
re-arm loop. Content controllers decouple from the view model through delegate protocols; their
hosts implement the delegates and forward the user's choice on.

Constraints the file layout does not show:

- **No shared callout, form container, or base class.** Consistency comes from shared token sets
  (`CalloutStyle`, `GroupedFormStyle`, `Spacing`, `Typography`), not inheritance; genuinely
  shareable controllers are reused by init parameterization.
- **Popover anchors target a wrapper `NSView`, never an inner control**, so
  `NSPopover.preferredEdge` is interpreted in an unflipped coordinate system.
- **The clipboard window renders inline RTF only, never HTML.**

`VMSettingsViewController` serves both attachment lists — storage disks and removable media — from
one set of row/menu/popover builders parameterized by `AttachmentKind`, dispatching on an
`AttachmentRef(kind:id:)`, rather than a duplicated implementation per list.

```
NSSplitViewController (MainWindowController)
├── Sidebar: SidebarViewController → NSOutlineView (source list) → SidebarVMRowCellView (per VM)
└── Detail:  DetailContainerViewController  (owns DetailAlertsPresenter)
    ├── VMDisplayBackingView (layered on top; VZVirtualMachineView + overlays)
    └── DetailEmptyStateView ⇆ VMDetailRouterViewController  (routes via DetailRoute.resolve)
            ├── VMSettingsViewController                   (stopped / error / running-settings)
            ├── InitialBootBannerView + VMSettingsViewController
            ├── DetailStatusPlaceholderViewController      (preparing / transition)
            ├── MacOSInstallProgressViewController         (installing)
            └── VMDisplayPlaceholderContentViewController  (external / suspended / unavailable)

VMCreationWizardViewController (modal sheet, presented by DetailContainerViewController)
├── OSSelectionContentViewController
├── IPSWSelectionContentViewController / BootConfigContentViewController
├── ResourceConfigContentViewController
└── ReviewContentViewController
```

**Serial console.** `VMInstance.startSerialReading` is the guest output pipe's single reader; it
fans out to `serial.log` (authoritative, always on) and to `SerialSocketRelay` (best-effort tee,
gated on `serialSocketRelayEnabled`). The relay's `AF_UNIX` socket is the sole host-side writer of
serial input. There is no in-app terminal emulator — emulation is delegated to the user's terminal.

### Data Flow

```
AppDelegate
    ├── creates → VMLibraryViewModel (owns [VMInstance])
    │                 ├── VMStorageService
    │                 ├── DiskImageService
    │                 ├── VMDirectoryWatcher, SystemSleepWatcher
    │                 └── FileSystemOperating (trash/remove seam; shared with the coordinator)
    ├── creates → VMLifecycleCoordinator
    │                 ├── VirtualizationService
    │                 ├── MacOSInstallService
    │                 ├── IPSWService
    │                 └── USBDeviceService
    ├── creates → MainWindowController (NSSplitViewController + NSToolbar)
    ├── manages → VMDisplayWindowController (per VM)
    └── manages → ClipboardWindowController (per VM)

AppKit views ──observe──→ VMLibraryViewModel ──delegates──→ VMLifecycleCoordinator ──→ Services
                          VMLibraryViewModel ──presents──→ VMLibraryPresenting (DetailContainerViewController)
```

### Utilities

- `ObservationLoop` — `observeRecurring(track:apply:)`, the standard observation seam. Returns a
  cancel token the caller stores; the loop stops when it deallocates.
- `PathValidation` — the shared resolve-symlinks → exists → type → permissions check for
  user-supplied paths.
- `NSWindowExtensions.withStableContentSize(_:styleMask:contentViewController:)` — the one place
  the "re-apply the content size *after* assigning `contentViewController`" ordering lives.
- `SecurityScopedBookmark` / `ScopedAccess` — capture and RAII resolution of app-scoped bookmarks
  (rules in [AGENTS.md](../AGENTS.md#app-sandbox-rules)).
- `AppPreferences` — the `UserDefaults`-backed preference store, injected (defaulting to `.shared`)
  so tests can substitute an ephemeral suite.
- `SheetPresenter`, `PopoverPresenter`, `DetailAlertsPresenter` — the presentation seams the view
  model and the detail container present through.

### Shared package (KernovaKit)

`KernovaKit` is the local SwiftPM package shared between the host app and the guest agent — the
vsock wire protocol, the clipboard domain model and file staging/archive, the File Provider layer,
and cross-cutting helpers. **New host/guest-identical code belongs here**, not copied into both
targets.

The package also vends `KernovaTestSupport`, the single shared copy of the test wait primitives every
test target imports. It must keep **no dependency on `KernovaKit`** and is **never linked
into a shipping target** — nothing enforces either.

## Key Design Decisions

### Pure AppKit

`NSSplitViewController`, `NSToolbar`, `NSOutlineView`, `NSWindow`; the app target imports no
SwiftUI. The chrome this app depends on — toolbar item
validation, sidebar collapsibility, popover and sheet anchoring, split-view behavior — is
controlled directly through AppKit or not at all.

### The VM bundle owns everything a VM needs

Each VM is a `.kernova` package directory holding `config.json`, the disk image, auxiliary storage,
save files, and serial logs, with every in-bundle path derived by `VMBundleLayout`. **Nothing a VM
needs may live outside its bundle**: move, copy, delete, and drag-and-drop import all treat it as
one atomic Finder item, and a relocated VM has no other way to carry its state. User-picked
external attachments are the deliberate exception, and they carry bookmarks (below).

### ASIF disk images from bundled templates

Disk images use Apple Sparse Image Format. `DiskTemplates/` holds pre-built lzfse-compressed
templates that `DiskImageService` decompresses in-process at VM creation. macOS 26
exposes no in-process ASIF-creation API and a sandboxed app cannot reach `hdiutil` or `diskutil`,
so every disk shape ships as a bundled template.

### Apple Silicon only

`ARCHS = arm64` project-wide. Virtualization.framework gates the macOS-guest APIs (`VZMacOSInstaller`, `VZMacOSRestoreImage`, `VZMacAuxiliaryStorage`, recovery boot) and `saveMachineStateTo`/`restoreMachineStateFrom` to Apple Silicon.

### App Sandbox with per-path security bookmarks

Every user-picked external path — external `StorageDisk`s, `RemovableMediaItem`s,
`SharedDirectory`s, Linux `kernelPath`/`initrdPath`, a local IPSW — carries an optional
`bookmark: Data?` beside its raw path in `config.json`. `VMInstance.openRuntimeFileAccess()`
resolves them per boot attempt, healing stale bookmarks and moved paths back into the config.

**Scopes stay open for the whole VM runtime, not just across the config-build call.** VZ opens its
fds at config-build time with no published retention guarantee, and an unbalanced release leaks
kernel resources until relaunch — hence one owner (`RuntimeFileAccess`) and one release point
(`tearDownSession`).

## Helper Targets

- **KernovaRelaunchHelper** — a watchdog embedded in `Contents/MacOS/`, spawned by `AppDelegate`
  during a quit that followed a TCC revocation. It watches the app's PID and relaunches through
  `NSWorkspace`. Sandboxed with `app-sandbox` + `inherit`.

- **KernovaMacOSAgent** — `Kernova Guest Agent.app`, the `.accessory` menu-bar app that runs inside
  macOS guests, holding three independent vsock connections to the host (control, log forwarding,
  clipboard). It is not embedded as a bundle: a build phase `ditto`-copies it into
  `Contents/Resources/KernovaMacOSAgent.dmg`, so it must already carry its final Developer ID
  signature when the DMG is baked — export-time re-signing cannot reach inside a DMG resource
  ([SANDBOX.md](SANDBOX.md)); version bumps are in [BUILD.md](BUILD.md).

  The host's `toggleGuestAgentDisk` menu item attaches that DMG to a running VM as USB mass storage;
  the guest user runs its `install.command`, which stages the bundle into `~/Applications` and
  registers a user LaunchAgent; the host auto-ejects once the agent handshakes a current version
  (`VMInstance.onAgentBecameCurrent`). The agent runs `NSApplication.run()`, **not** `dispatchMain()`
  — pasteboard promise callbacks (`provideDataForType`) are delivered by CFRunLoop and never fire
  under a GCD-only main queue. Its executable and Swift module stay `KernovaMacOSAgent` while the
  product is `Kernova Guest Agent`, because the LaunchAgent's `ProgramArguments` path and
  `install.command` need a space-free leaf.

- **KernovaMacOSAgentFileProvider** — an `NSFileProviderReplicatedExtension` in the agent's
  `Contents/PlugIns/` that makes a host→guest file paste lazy: the agent writes the offer into a
  manifest in the shared app-group container and puts a dataless domain placeholder URL on the guest
  pasteboard, and the extension's enumerator reads that manifest. Being sandboxed it cannot open
  vsock, so `fetchContents` relays the pull back to the agent over the `NSFileProviderServicing`
  anonymous-XPC connection — the agent is the XPC *client* and exports the relay, the extension calls
  it back **asynchronously** (blocking there stalls the framework's serialised reconnect), and a
  Darwin notification is the reconnect doorbell. No bytes cross XPC: the relay carries
  `(generation, repIndex)` and replies with a staged app-group path.

  macOS keeps a third-party File Provider extension disabled until the user enables it under System
  Settings, so a registered domain is not yet a usable one — both extensions track availability
  event-driven off `NSFileProviderDomain.userEnabled`.

- **KernovaFileProvider** — the host-side mirror in the app's `Contents/PlugIns/`, running the same
  shared `FileProviderExtension` under `.host` config for guest→host "Copy to Mac", with the same
  inverted wiring and the app as XPC client. Both ends pin their peer with
  `NSXPCConnection.setCodeSigningRequirement`; the team OU is read from the running executable's own
  signature (`KernovaCodeSignature.teamIdentifier()`) rather than hardcoded, so the pin is correct
  for whichever team built the app and matches Apple Development and Developer ID alike.

- **KernovaMacOSAgentTests** — a standalone bundle with no `TEST_HOST`/`BUNDLE_LOADER`. Because
  `KernovaMacOSAgent` is an application target its symbols are not linkable, so this bundle compiles
  the agent's sources directly (all but `AgentAppDelegate.swift`, the `@main` entry) — which is also
  what makes `internal` members reachable without `@testable import`. It is non-parallelizable: the
  compiled-in sources carry global state (`VsockLogBridge.connection`).

## Dependencies

| Framework | Role |
|---|---|
| **Virtualization** | VM lifecycle |
| **AppKit** | All UI |
| **Observation** | `@Observable` models and view models |
| **FileProvider** | Both clipboard File Provider extensions |
| **ServiceManagement** | `SMAppService.mainApp` — Open at Login |
| **AppleArchive** | In-process `.aar` archiving for clipboard directory transfers |
| **UniformTypeIdentifiers** | The `.kernova` bundle's `UTType` |
| **AVFoundation** | Microphone permission status |
| **ImageIO** | Thumbnail-only decoding for clipboard previews |
| **CryptoKit** | SHA-256 → the synthesized main disk's stable UUID |
| **os** | `os.Logger` |
| **SwiftProtobuf** | Wire-protocol codegen and runtime; `KernovaKit` only |

