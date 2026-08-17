# Architecture

## Overview

Read this before a structural change — a new service or protocol, a changed data flow, a changed
actor isolation. It records what exists and how the pieces connect; what a component *does* is
owned by its own doc comment.

Kernova manages virtual machines through Apple's Virtualization.framework, with macOS and Linux
guests. Pure AppKit (no `import SwiftUI` in the app target), Swift 6 strict concurrency,
no non-Apple dependencies. The app targets macOS 26; the guest agent and `KernovaKit` deploy back
to macOS 12 so the agent runs in every macOS guest the catalog can install.

Clipboard rules are in [CLIPBOARD.md](CLIPBOARD.md), sandbox/launch model in
[SANDBOX.md](SANDBOX.md), toolbar construction in [TOOLBAR.md](TOOLBAR.md).

## Component Map

### App Layer

- `AppDelegate` — the entry point. Creates `VMLibraryViewModel` and `VMLifecycleCoordinator`, owns
  the application menu, and tracks window controllers in dictionaries keyed by VM UUID, so one VM
  can have a detail pane, a display window, and a clipboard window open at once.
- `HostAgentStatusItemController` — the menu-bar status item. Kernova runs as a resident
  `.accessory` app whose VMs keep running with no window open, so this is the only affordance while
  headless; under XCTest (`isTestHost`) the same binary is instead a plain foreground test host.
  Present exactly while *Continue running in Status Bar* is on, created and torn down live as the
  toggle flips (`AppDelegate.syncStatusItem`). With it off there is no headless state to reach: the
  last window close quits through the same gate a full quit uses.
- `MainWindowController` — the library window: a `SnapToFitSplitViewController` holding the
  `SidebarViewController` source list and `DetailContainerViewController`, plus an `NSToolbar`.
- `VMToolbarManager` — the toolbar items shared between the library window and the pop-out display
  window; window-specific items stay with their own controller.
- `VMDisplayWindowController`, `ClipboardWindowController` — per VM, created and tracked by
  `AppDelegate`. `SettingsWindowController` is an app-level singleton.
- `DisplayBootGeometryProviding` — the App→ViewModel seam for on-screen geometry. `AppDelegate`
  conforms, resolving `displayPreference` to the pop-out window, the target screen, or the inline
  detail container; `VMLibraryViewModel.start` consults it on a cold boot and writes the computed
  resolution through `updateConfiguration` before the VZ configuration is built.

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
- `VMStatus`, `VMBootMode`, `VMGuestOS` — enums.
- `GuestSetupState` — the runtime step model behind the one setup-progress view both guests share,
  with per-flow copy supplied by a `GuestSetupDescriptor`.

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
- `DownloadService` (a `final class`, for `URLSession` lifetime) — streams a remote file into a
  resumable `.kernovadownload` bundle beside its destination, serialized per destination path by a
  static claim table so two callers can never write one bundle.
- `IPSWService` — resolves the latest supported restore image through VZ, and hands restore-image
  transfers to the `DownloadService` it owns.
- `RestoreImageCatalogService` — decodes the bundled snapshot of selectable macOS restore images,
  `Kernova/Resources/RestoreImageCatalog.json`, backing the wizard's "Choose a Version…" source. It
  reaches no network; only the image the user picks is fetched, by `IPSWService`.
- `LocalRestoreImageInspector` — reads a restore image already on disk through `VZMacOSRestoreImage`,
  which loads from a file URL, so the version, build and supported-configuration verdict are the
  framework's own. Consulted before the wizard adopts a file it did not download itself.
- `RestoreImageProbeService` (a `final class`, for `URLSession` lifetime) — establishes that a
  user-supplied URL serves an installable restore image, and how large it is, before any download.
  `Tools/regen-restore-image-catalog.swift` applies the same installability check to every catalog
  candidate, which is what puts a pasted URL on the same footing as a catalog row. Sizing goes
  through `RemoteFileSizeProbe`, the HEAD/ranged-GET helper it shares with the Linux resolver.
- `LinuxImageCatalogService` — decodes the bundled snapshot of curated Linux installer images,
  `Kernova/Resources/LinuxImageCatalog.json`, backing the Linux boot step's "Choose a
  Distribution…" source. It reaches no network; an entry names a directory, an ISO filename glob,
  and a checksum manifest rather than a fixed URL.
- `LinuxImageResolveService` (a `final class`, for `URLSession` lifetime) — turns a Linux image
  source into the file to fetch, returning its URL, SHA-256, and size. A catalog entry resolves
  against the manifest its distribution serves; a user-supplied URL names its own file and
  carries only the digest the user typed, so all that is read is its length. The wizard's
  "Image URL…" check and the install pipeline both go through it, so one set of admission rules
  governs both.

`ConfigurationBuilder` translates a `VMConfiguration` into a `VZVirtualMachineConfiguration` — the
single VZ-facing translation point, covering boot loader, CPU, memory, storage, network, display,
input, audio, the Linux SPICE console port, and the macOS `VZVirtioSocketDeviceConfiguration`.

The network attachment follows the VM's persisted mode: shared over the app-managed vmnet
shared network in an entitled build (system NAT otherwise), bridged over a host interface
resolved through `BridgedInterfaceProviding` — the same seam the settings section's Mode picker
reads its interface list from — or host-only on the app-managed host-mode network, both reached
through `VmnetNetworkProviding`. A bridged VM whose interface cannot resolve, or a vmnet network
that cannot materialize, builds the device detached rather than failing the boot or restore.

`VmnetNetworkService` (lock-guarded `Sendable`, process-wide — it serves `ConfigurationBuilder`'s
off-main assembly and the main-actor live-switch path) owns the app's managed vmnet networks and
the per-VM DHCP reservations and port-forwarding rules riding them: each VM holds a slot keyed on
its persisted MAC, the slot's derived address is what the settings pane's IP Address row shows and
what a Shared Network VM's rules forward to, and both are kept in step with configurations through
`VMLibraryViewModel`'s persistence funnel — which also recreates an app-managed network, once no VM
is attached to it, when the reservations or rules it carries no longer match the ones configured.
The service
materializes each network lazily over the `VmnetNetworkOperating` seam and holds the ref until
the app exits, so every concurrent VM in the mode shares the one network; addressing and slots
stay stable across launches by persisting each network's record to
`Application Support/Kernova/networks.json` and pinning the addressing onto the recreated
network at next use.

While a session runs, `NetworkAttachmentCoordinator` (one per session, owned by `VMInstance`,
activated when the VM reaches `.running`) keeps the live attachment realizing the persisted mode.
It reconciles on VZ's attachment-disconnect delegate callback, on host link changes observed
through `NetworkLinkObserving` (`HostNetworkLinkObserver`, SCDynamicStore), and on live
mode/interface edits arriving through the `applyLivePolicy` path, driving the device through the
`NetworkDeviceControlling` seam. A session with no realizable attachment surfaces as
`VMInstance.networkAttachmentPending`, which the sidebar status affordances read.

**VZ is only ever handed symlink-resolved URLs.** VZ resolves no symlinks and rejects a path
containing one in any component, reporting it as a missing or invalid file while `FileManager`
reports the file present and readable. `ConfigurationBuilder` and `MacOSInstallService` resolve
through `PathValidation` before every hand-off. This is not defensive: under the sandbox
`.downloadsDirectory` is the container's `Downloads`, itself a symlink to the real one.

The vsock stack (macOS guests only):

- `VsockPorts` — the port registry. Each service gets its own listener instead of in-band
  multiplexing, and the clipboard and drop kinds get a second port apiece, carrying one
  guest-dialed connection per transfer in place of a long-lived channel;
  `KernovaMacOSAgent/VsockPorts.swift` mirrors the same assignments guest-side. What a connection
  costs, and why nothing above the kernel meters a
  stream: [research/2026-08-17-vsock-stalled-receiver-and-accept-latency.md](research/2026-08-17-vsock-stalled-receiver-and-accept-latency.md).
- `VsockListenerHost` — one `VZVirtioSocketListener` per port, bridging an accepted connection to a
  `VsockChannel` or, on a data port, handing the raw descriptor to an `onAcceptFd` closure instead.
  Its `shouldAdmit` predicate refuses a connection before any channel is built; `VMInstance` wires
  the log, clipboard, drop and both data listeners to `featureChannelAdmission`, so no feature
  channel is accepted before the control handshake completes, and each names the guest
  capability it additionally requires. Socket-buffer sizing and its
  measurements: [research/2026-07-13-vsock-transport-throughput.md](research/2026-07-13-vsock-transport-throughput.md).
- `VsockControlService` — `@MainActor` `@Observable` owner of the always-on control channel:
  `Hello`/`Heartbeat` exchange, a liveness watchdog, the observed `agentVersion`, and `PolicyUpdate`
  pushes carrying an `AgentPolicySnapshot`. `VMInstance.makeControlService(for:)` builds it with
  four closures that read the instance lazily, so a reconnect picks up live toggles and a
  pause/resume needs nothing re-pushed: current policy, observed agent info, whether the guest is
  frozen (which suspends both the heartbeat and the liveness deadline), and a channel-loss
  notification that re-arms `VMInstance`'s agent-arrival watchdog. Installed for every macOS guest
  with a socket device, independent of clipboard sharing.
- `VsockGuestLogService` — forwards guest `LogRecord` frames into the `app.kernova.guest` subsystem.
- `VsockDropService` — `@MainActor` `@Observable` owner of the drop channel, send-only, driving
  `KernovaKit`'s `ClipboardEndpoint`. Files dragged onto `VMDisplayBackingView` become a
  `DropOffer` the guest pulls representation by representation over the same transfer machinery the
  clipboard uses; the guest writes them into its Downloads folder and replies `DropComplete`.
  Installed for every guest with a socket device, gated only on the guest's `drop.files.v3`.
  `VMInstance.displayDropAvailability` is the single read site deciding whether the display
  registers as a drag destination at all.

The log and clipboard listeners are gated on their configuration toggles and re-evaluated at
runtime through `VMInstance.applyLivePolicy(oldConfig:newConfig:)`, the clipboard's data listener
rising and falling with it; the control, drop and drop-data listeners have no toggle to track.
Linux clipboard sharing is restart-only — its SPICE port must be declared at config-build time.

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
  `ClipboardEndpoint`. Offers are metadata-only; a transfer's bytes ride the data connection opened
  for it. `EngineClock` is the one time seam KernovaKit and the agent share — a single
  `EngineInstant` timeline for every conformance, so the macOS 13+ and macOS 12 clocks and a
  manually advanced test clock are interchangeable at construction.
- `ClipboardEndpoint` — `KernovaKit`'s `@MainActor` owner of one clipboard-protocol control
  channel, parameterized by role (`.host`/`.guest`) and kind (`.clipboard`/`.drop`): what each side
  has offered and every transfer between them. `Configuration.dataLink` is how it reaches the
  kind's data port — `.accepts` on the host, where `acceptDataConnection(fd:)` takes the listener's
  descriptor and moves it off the main queue, and `.dials` on the guest, which opens each
  connection itself. Its `ClipboardEndpointDelegate` is the seam an owner sees — offer arrival and
  retraction, refusals, status activity, the channel's end. All four owners drive one: the two host
  services above and the guest agent's `VsockGuestClipboardAgent`/`VsockGuestDropAgent`.
- `ClipboardControlSession`, `ClipboardTransferInbox`, `ClipboardTransferOutbox`,
  `ClipboardTransferSender`, `ClipboardTransferReceiver` — the layers beneath that endpoint. The
  session owns the control channel and the two transfer tables; the inbox holds what this side is
  pulling and the outbox what it is serving, both lock-guarded rather than actor-isolated so a
  transfer's own thread can reach them. Each live transfer gets a sender or a receiver on its own
  serial queue, owning that connection's descriptor through the payload and the trailer that ends
  it. `ClipboardDataConnection` (descriptor mechanics and the trailer) and
  `ClipboardArchiveCodec` (AppleArchive encode/extract straight onto the socket) are the stateless
  namespaces those queues call into.
- `HostClipboardPublisher`, `ClipboardPassthroughCoordinator` — host-side publication of inbound
  guest content, and the auto-publish path. Both reach the pasteboard through KernovaKit's
  `ClipboardPasteboardPublisher` — the one promised write on either side of the wire, driven by the
  guest agent too.
- `ClipboardTransferReporter` — one per `VMInstance`, fed by `VsockClipboardService`,
  `VsockDropService` and `ClipboardPassthroughCoordinator`. `VMInstance.clipboardTransferReport`
  mirrors it as the observable value every surface renders — the clipboard window's bar and
  banner, the toolbar button's ring, and `HostAgentStatusItemController`'s dropdown line and
  notice popover. The status item computes the newest running report across
  `VMLibraryViewModel.instances` rather than holding a registry of its own.
- `ClipboardTransferOperation` — KernovaKit's lock-based per-operation accumulator, opened by
  both host services and by the guest agent's clipboard and drop agents, which drive it from
  non-`@MainActor` callbacks and per-transfer queues.
- `AgentStatus` — the enum driving install/update/reinstall affordances, sourced from
  `VsockControlService` (macOS) or `SpiceClipboardService` (Linux) and read through
  `VMInstance.agentStatus`.
- `KernovaMacOSAgentInfo` — accessors for the bundled agent's version and installer DMG. The
  version comes from a build-phase-written sidecar so it cannot drift from the shipped binary
  ([BUILD.md](BUILD.md)).

Also here: `LoginItemService` (the `SMAppService.mainApp` wrapper behind the login-item toggle),
`EntitlementService` (what this build's signature authorizes, read from the process's own
signature via `SecTaskCopyValueForEntitlement`, so feature UI can degrade in builds signed
without a restricted entitlement), `AttachmentFileMonitor` (existence watching for the settings
attachment rows), `RuntimeFileAccess` (per-boot security-scoped access, released once in
`tearDownSession`), and `SerialSocketRelay` (below).

**Configuration writes have one door.** Every write — settings controls, install/uninstall flows,
rename, and guest-driven `VMInstance.onUpdateConfiguration` callbacks — routes through
`VMLibraryViewModel.updateConfiguration(of:mutate:)`, which persists and then calls
`applyLivePolicy`. No control writes `instance.configuration` directly.

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
  `IPSWService`, `USBDeviceService`, and the Linux resolve/download seams (`LinuxImageResolving`,
  `Downloading`), and orchestrates multi-step flows: a macOS install, and a Linux image pick's
  resolve → download → SHA-256 verify → attach pipeline, whose verify step runs only where a
  digest exists to check against, each driven by the install context
  persisted on `VMConfiguration` (`installContext` / `linuxInstallContext`) until it completes.
  It serializes lifecycle operations per VM; `stop` and `forceStop` deliberately bypass that
  serialization so a hung operation can always be cancelled.
- `VMCreationViewModel` — a pure `@Observable` state machine for the creation wizard, with no
  UI-framework dependency. Each macOS restore-image source is backed by an injected service
  protocol, so the wizard can name the version, build and size the source will install before
  anything is downloaded — including "Download Latest", which reaches `IPSWProviding` for what VZ
  would resolve. The Linux boot step's two download sources are backed the same way, by
  `LinuxImageCatalogProviding` and `LinuxImageResolving`.
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
            ├── VMSettingsViewController                    (stopped / running-settings)
            ├── DetailBannerView + VMSettingsViewController (initial boot / error)
            ├── DetailStatusPlaceholderViewController       (preparing / transition)
            ├── GuestSetupProgressViewController            (setup)
            └── VMDisplayPlaceholderContentViewController   (external / suspended / unavailable)

VMCreationWizardViewController (modal sheet, presented by DetailContainerViewController)
├── OSSelectionContentViewController
├── IPSWSelectionContentViewController / BootConfigContentViewController
├── ResourceConfigContentViewController
└── ReviewContentViewController
```

**Serial console.** `VMInstance.startSerialReading` is the guest output pipe's single reader; it
fans out to `serial.log` (authoritative, always on, size-capped by `SerialLogWriter`) and to
`SerialSocketRelay` (best-effort tee, gated on `serialSocketRelayEnabled`). The relay's `AF_UNIX` socket is the sole host-side writer of
serial input. There is no in-app terminal emulator — emulation is delegated to the user's terminal.

### Data Flow

```
AppDelegate
    ├── creates → VMLibraryViewModel (owns [VMInstance])
    │                 ├── VMStorageService
    │                 ├── DiskImageService
    │                 ├── VMDirectoryWatcher, SystemSleepWatcher
    │                 └── FileSystemOperating (trash/remove seam; also held by DownloadService)
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
vsock wire protocol, the clipboard domain model and file staging/archive, and cross-cutting
helpers. **New host/guest-identical code belongs here**, not copied into both targets.

The package also vends `KernovaTestSupport`, the single shared copy of the wait primitives, channel
and frame fixtures, and production-seam doubles every test target imports. It is **never linked into
a shipping target** — nothing enforces that.

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
  macOS guests, holding four long-lived vsock connections to the host (control, log forwarding,
  clipboard, drop) and dialing one more per transfer through `VsockGuestDataDialer`, which reuses
  `VsockGuestClient`'s per-OS connect paths. Its clipboard and drop agents each drive a
  `ClipboardEndpoint`, the same KernovaKit type the host services do. It is not embedded as a bundle: the `Package Guest Agent DMG` build phase produces
  `Contents/Resources/KernovaMacOSAgent.dmg`, so it must already carry its final Developer ID
  signature when the DMG is baked — export-time re-signing cannot reach inside a DMG resource
  ([RELEASING.md](RELEASING.md)); version bumps are in [BUILD.md](BUILD.md).

  That DMG reaches a guest on one of two buses, and `GuestAgentDiskDelivery` owns the choice:
  the host's `toggleGuestAgentDisk` menu item hot-plugs it as USB mass storage, while a guest too
  old to bind a driver to one ([VERSION-FLOORS.md](VERSION-FLOORS.md)) instead gets it on
  `vzConfig.storageDevices` at every boot, appended by `ConfigurationBuilder` and never persisted
  into `config.storageDisks`. Either way the guest user runs its `install.command`, which stages
  the bundle into `~/Applications` and registers a user LaunchAgent; the host auto-ejects the USB
  attachment once the agent handshakes a current version (`VMInstance.onAgentBecameCurrent`). The agent runs `NSApplication.run()`, **not** `dispatchMain()`
  — pasteboard promise callbacks (`provideDataForType`) are delivered by CFRunLoop and never fire
  under a GCD-only main queue. Its executable and Swift module stay `KernovaMacOSAgent` while the
  product is `Kernova Guest Agent`, because the LaunchAgent's `ProgramArguments` path and
  `install.command` need a space-free leaf.

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
| **ServiceManagement** | `SMAppService.mainApp` — the login-item registration behind Open at Login |
| **AppleArchive** | In-process LZ4 archiving for every file and folder transfer, encoded onto the wire |
| **UniformTypeIdentifiers** | The `.kernova` bundle's `UTType` |
| **AVFoundation** | Microphone permission status |
| **ImageIO** | Thumbnail-only decoding for clipboard previews |
| **CryptoKit** | SHA-256 → the synthesized main disk's stable UUID |
| **os** | `os.Logger` |
| **SwiftProtobuf** | Wire-protocol codegen and runtime; `KernovaKit` only |

