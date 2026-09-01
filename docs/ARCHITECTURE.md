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

- `AppDelegate` — the entry point. Creates `VMLibraryViewModel`, `VMLifecycleCoordinator`,
  `AppWindowRegistry` and `MainMenuController`, and decides the activation policy, the quit gate
  and idle termination.
- `MainMenuController` — the one owner of the menu bar: its construction, the rebuilds an opening
  menu asks for, and menu-item validation. It reaches the app through `MainMenuHosting`, conformed
  to by `AppDelegate`, which keeps the `@objc` actions the items name — every call site dispatches
  them nil-target down the responder chain.
- `AppWindowRegistry` — the one owner of which user-facing windows exist and whether any is on
  screen: the library window, the Settings window, the per-VM clipboard windows, and the
  `VMDisplayPlacementController` it holds. It reaches the app through `AppWindowRegistryHosting`,
  conformed to by `AppDelegate`.
- `VMDisplayPlacementController` — the one owner of where each VM's display lives: the display-window
  registry, and the sole writer of `VMInstance.displayMode` and `VMConfiguration.displayPreference`
  for every transition. It reaches the app through `VMDisplayPlacementHosting`, conformed to by
  `AppDelegate`.
- `HostAgentStatusItemController` — the menu-bar status item, created and torn down by `AppDelegate`
  as *Continue running in Status Bar* flips. Kernova is a resident `.accessory` app whose VMs keep
  running with no window open, so this is the only affordance while headless; under XCTest
  (`isTestHost`) the same binary is a plain foreground test host instead.
- `MainWindowController` — the library window: a `SnapToFitSplitViewController` holding the
  `SidebarViewController` source list and `DetailContainerViewController`, plus an `NSToolbar`.
- `VMToolbarManager` — the toolbar items shared between the library window and the pop-out display
  window; window-specific items stay with their own controller.
- `VMDisplayWindowController` — per VM, created by `VMDisplayPlacementController`, to which it
  reports the transitions AppKit performs. `ClipboardWindowController` is per VM under
  `AppWindowRegistry`; `SettingsWindowController` is an app-level singleton.
- `DisplayBootGeometryProviding` — the App→ViewModel seam for on-screen geometry, conformed to by
  `AppDelegate` and read by `VMLibraryViewModel.start` before the VZ configuration is built.

Lifecycle commands surface on the menu bar, the sidebar context menu, and the toolbar, and all
three take their titles from `VMInstance` display helpers rather than spelling their own — no
surface can name an action differently. Advanced actions are always visible in the menu bar and
Option-revealed in the sidebar, gated by `AppPreferences.alwaysShowAdvancedOptions`.

### Models

- `VMConfiguration` — a VM's persisted identity: a `Codable` `Sendable` struct written as
  `config.json` inside the VM bundle.
- `VMInstance` — a VM's runtime representation: an `@Observable` `@MainActor` class wrapping a
  `VMConfiguration`, an optional `VMSessionContext`, and a `VMLifecyclePhase`. What outlives a
  session belongs to it — the admission gate, the data sinks, the transfer reporter, the host
  clipboard publisher — and it projects the context's state read-only for its callers.
- `VMLifecyclePhase` — where a VM is in its lifecycle, and the one value its `VMStatus`, its failure
  message and every liveness predicate are read off. A live phase carries the identity of the
  session it describes.
- `VMSessionContext` — everything scoped to one `VZVirtualMachine`'s lifetime, so its state is
  created and released as a unit rather than as loose fields on `VMInstance`, which holds exactly
  one optional of this type for a session's duration.
- `VMSession` — one running VM's isolation domain: an actor whose executor is the private serial
  queue its `VZVirtualMachine` was created with, and the only type that calls into that VM or any
  of its device objects. It retains the VM's `VsockListenerHost`s, each for as long as its port is
  bound. VZ's delegate callbacks arrive on that queue and leave as `VMSessionEvent`s
  stamped with the session's id, which `VMInstance` hops to main and drops once the id no longer
  names the live session.
- `VMBundleLayout` — a `Sendable` struct deriving every in-bundle path from the bundle root; the one
  place path logic lives.
- `VMSnapshot` / `VMSnapshotManifest` — a named restore point and the `Snapshots/manifest.json`
  payload listing them.
- `VMStatus` — the vocabulary a phase projects into for the wire and the UI, carrying no predicates
  of its own. `VMBootMode`, `VMGuestOS` — plain enums.
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
substitute mocks. Services split by concurrency: those that mutate `VMInstance` are `@MainActor`;
stateless ones are `Sendable` structs.

`@MainActor`:

- `VirtualizationService` — start, stop, pause, resume, save and restore VM state, plus snapshot
  capture and revert against an injected `VMSnapshotStoring`.
- `MacOSInstallService` — restore-image load, platform-file creation, and the `VZMacOSInstaller`
  run with KVO progress.
- `USBDeviceService` — runtime USB mass-storage attach/detach against the live XHCI controller.
  Owned by `VMLifecycleCoordinator`.
- `SystemSleepWatcher` — `NSWorkspace` sleep/wake observer owned by `VMLibrary`, which
  auto-pauses running VMs before sleep and resumes them on wake.

`Sendable` structs:

- `VMStorageService` — creates, lists, clones and deletes VM bundles under
  `~/Library/Application Support/Kernova/VMs/`.
- `VMSnapshotStore` — owns the `Snapshots/` directory inside a VM bundle.
- `DiskImageService` — creates ASIF disk images by decompressing bundled templates in-process.
- `DownloadService` — streams a remote file into a resumable bundle beside its destination,
  serialized per destination path so two callers can never write one bundle.
- `IPSWService` — resolves the latest supported restore image through VZ, handing the transfer to
  the `DownloadService` it owns.
- `RestoreImageCatalogService`, `LinuxImageCatalogService` — decode the bundled catalog resources
  behind the wizard's "Choose a Version…" and "Choose a Distribution…" sources; neither networks.
- `LocalRestoreImageInspector` — reads a restore image already on disk through `VZMacOSRestoreImage`.
- `RestoreImageProbeService`, `LinuxImageResolveService` — admit a remote restore image or Linux
  installer before any download, sizing it through the `RemoteFileSizeProbe` they share. The
  wizard's "Image URL…" check and the install pipeline both reach the resolver.

`ConfigurationBuilder` translates a `VMConfiguration` into a `VZVirtualMachineConfiguration` — the
single VZ-facing translation point for every device a VM gets.

The network attachment follows the VM's persisted mode: shared over the app-managed vmnet
shared network in an entitled build (system NAT otherwise), bridged over a host interface
resolved through `BridgedInterfaceProviding` — the same seam the settings section's Mode picker
reads its interface list from — or host-only on the app-managed host-mode network, both reached
through `VmnetNetworkProviding`. A bridged VM whose interface cannot resolve, or a vmnet network
that cannot materialize, builds the device detached rather than failing the boot or restore.

`VmnetNetworkService` (lock-guarded `Sendable`, process-wide — it serves `ConfigurationBuilder`'s
off-main assembly and the main-actor live-switch path) owns the app's managed vmnet networks and
the per-VM DHCP reservations and port-forwarding rules riding them, materialized over the
`VmnetNetworkOperating` seam. Each VM holds a slot keyed on its persisted MAC, and slots and rules
alike are kept in step with configurations through `VMLibrary`'s persistence funnel.

While a session runs, `NetworkAttachmentCoordinator` (one per session, owned by
`VMSessionContext`, activated when the VM first reaches `.running`) keeps the live attachment
realizing the persisted mode, driving the device through `NetworkDeviceControlling` and reconciling
on VZ's attachment-disconnect callback, on `NetworkLinkObserving` (`HostNetworkLinkObserver`,
SCDynamicStore), and on `applyLivePolicy` edits. A session with no realizable attachment surfaces
as `VMInstance.networkAttachmentPending`.

**VZ is only ever handed symlink-resolved URLs.** VZ resolves no symlinks and rejects a path
containing one in any component, reporting it as a missing or invalid file while `FileManager`
reports the file present and readable. `ConfigurationBuilder` and `MacOSInstallService` resolve
through `PathValidation` before every hand-off. This is not defensive: under the sandbox
`.downloadsDirectory` is the container's `Downloads`, itself a symlink to the real one.

The vsock stack (macOS guests only):

- `KernovaVsockPort` — the port registry. Each service gets its own listener instead of in-band
  multiplexing, and the clipboard and drop kinds get a second port apiece, carrying one
  guest-dialed connection per transfer in place of a long-lived channel. What a connection
  costs, and why nothing above the kernel meters a
  stream: [research/2026-08-17-vsock-stalled-receiver-and-accept-latency.md](research/2026-08-17-vsock-stalled-receiver-and-accept-latency.md).
- `VsockListenerHost` — one `VZVirtioSocketListener` per port, nonisolated so the whole accept path
  runs on whatever queue VZ delivers the callback on. Every feature listener is wired to the
  VM's `VsockAdmissionGate` — the lock-guarded snapshot the control service publishes its completed
  handshake and advertised capabilities into — so no feature channel is admitted before the
  handshake, and each names the guest capability it additionally requires. The two data listeners
  forward through a `VsockDataConnectionSink` apiece. Socket-buffer sizing and its
  measurements: [research/2026-07-13-vsock-transport-throughput.md](research/2026-07-13-vsock-transport-throughput.md).
- `VsockFeatureCoordinator` — the per-session owner of the four channels, one per
  `VMSessionContext`, driven by a static `VsockFeatureDescriptor` table saying what each channel
  binds, gates, builds and releases. The gate and both data sinks are the
  VM's and handed in, because the accept path reads them without touching the main actor.
- `VsockFeatureService` — the settle contract the four services conform to, which the coordinator
  wires at accept.
- `VsockControlService` — `@MainActor` `@Observable` owner of the always-on control channel:
  `Hello`/`Heartbeat` exchange, the observed `agentVersion`, and `PolicyUpdate` pushes carrying an
  `AgentPolicySnapshot`. Built per accepted channel by `VMInstance.makeControlService(for:)`, and
  installed for every macOS guest with a socket device, independent of clipboard sharing.
- `VsockGuestLogService` — forwards guest `LogRecord` frames into the `app.kernova.guest` subsystem.
- `VsockDropService` — `@MainActor` `@Observable` owner of the drop channel, send-only, driving
  `KernovaKit`'s `ClipboardEndpoint` over the same transfer machinery the clipboard uses, with
  `DropPromiseStaging` behind it for a drag carrying promises. Installed for a guest with a socket
  device whose `dropFilesEnabled` is set, gated in turn on the guest's `drop.files.v3`;
  `VMInstance.displayDropAvailability` is the single read site deciding whether the display
  registers as a drag destination at all.

The log, clipboard and drop listeners are gated on their configuration toggles and re-evaluated at
runtime through `VMInstance.applyLivePolicy(oldConfig:newConfig:)`, each pair's data listener rising
and falling with its channel; only the control listener has no toggle to track. Linux clipboard
sharing is restart-only — its SPICE port must be declared at config-build time.

Clipboard (principles and trade-off rules: [CLIPBOARD.md](CLIPBOARD.md)):

- `ClipboardServicing` — the `@MainActor` protocol both transports implement.
  `VMInstance.clipboardService` projects over the vsock service the feature coordinator owns and the
  SPICE one `VMSessionContext.clipboardService` holds, so the window controllers never branch on
  transport. Agent install/version state lives on `VsockControlService` instead, which runs whether
  or not clipboard sharing is enabled.
- `SpiceClipboardService` — the Linux transport, over raw `VZFileHandleSerialPortAttachment` pipes
  parsed by `SpiceAgentParser`. Text only.
- `VsockClipboardService` — the macOS transport, over `VsockChannel`, driving `KernovaKit`'s
  `ClipboardEndpoint`. Offers are metadata-only; a transfer's bytes ride its own data connection.
- `ClipboardEndpoint` — `KernovaKit`'s `@MainActor` owner of one clipboard-protocol control
  channel, parameterized by role (`.host`/`.guest`) and kind (`.clipboard`/`.drop`).
  `Configuration.dataLink` says how it reaches the kind's data port; `ClipboardEndpointDelegate` is
  the seam an owner sees. All four owners drive one: the two host services above and the guest
  agent's `VsockGuestClipboardAgent`/`VsockGuestDropAgent`.
- `ClipboardControlSession`, `ClipboardTransferInbox`, `ClipboardTransferOutbox`,
  `ClipboardTransferSender`, `ClipboardTransferReceiver` — the layers beneath that endpoint. The
  session owns the control channel and the two transfer tables, lock-guarded rather than
  actor-isolated so a transfer's own thread can reach them; each live transfer gets a sender or a
  receiver on its own serial queue, calling into the stateless `ClipboardDataConnection` and
  `ClipboardArchiveCodec` namespaces.
- `HostClipboardPublisher`, `ClipboardPassthroughCoordinator` — host-side publication of inbound
  guest content, and the auto-publish path. Both reach the pasteboard through KernovaKit's
  `ClipboardPasteboardPublisher` — the one promised write on either side of the wire, driven by the
  guest agent too.
- `ClipboardTransferReporter` — one per `VMInstance`, fed by `VsockClipboardService`,
  `VsockDropService` and `ClipboardPassthroughCoordinator`. `VMInstance.clipboardTransferReport`
  mirrors it as the observable value every surface renders; `HostAgentStatusItemController` ranks
  the running reports across `VMLibraryViewModel.instances` rather than keeping a registry.
- `ClipboardTransferOperation` — KernovaKit's lock-based per-operation accumulator, opened by both
  host services and by the guest agent's clipboard and drop agents, which drive it off main.
- `AgentStatus` — the enum driving install/update/reinstall affordances, sourced from
  `VsockControlService` (macOS) or `SpiceClipboardService` (Linux) and read through
  `VMInstance.agentStatus`.
- `KernovaMacOSAgentInfo` — accessors for the bundled agent's version and installer DMG, the version
  read from a build-phase-written sidecar ([BUILD.md](BUILD.md)).

Also here: `LoginItemService` (the `SMAppService.mainApp` wrapper behind the login-item toggle),
`EntitlementService` (what this build's signature authorizes, so feature UI can degrade in builds
signed without a restricted entitlement), `AttachmentFileMonitor` (existence watching for the
settings attachment rows), `RuntimeFileAccess` (per-boot security-scoped access, released once in
`VMSessionContext.tearDown`), and `SerialSocketRelay` (below).

**Configuration writes have one door.** Every write — settings controls, install/uninstall flows,
rename, and guest-driven `VMInstance.onUpdateConfiguration` callbacks — routes through
`VMLibrary.updateConfiguration(of:mutate:)`, which persists and then calls
`applyLivePolicy`. No control writes `instance.configuration` directly.

**Ephemeral Mode reverts through one seam.** `VMInstance.resetToStopped()` fires `onPoweredOff`,
which `VMLibrary` relays to the adapter, landing on the same revert a user confirms. A save-suspend tears the
session down without that hook, so a suspended session survives to revert at its next shutdown.

### ViewModels

- `VMLibrary` — the headless `@Observable` source of truth. Owns `[VMInstance]`, the selection and
  sidebar order (persisted through an injected `AppPreferences`), the library read and the
  directory/sleep watchers, the configuration-write funnel, and the DHCP-reservation and
  port-forwarding bookkeeping. It imports no AppKit and presents nothing: failures and the two
  per-instance hooks a verb answers leave through `onFailure`, `onAgentBecameCurrent` and
  `onPoweredOff`.
- `VMCommandCore` — the headless implementation of every VM verb, beneath the UI and every
  automation surface, conforming to the `VMCommanding` facade. `@MainActor` and deliberately not
  `@Observable`: it holds no state, only `VMLibrary` and `VMLifecycleCoordinator`. VMs are addressed
  by `VMSelector` and refusals speak one `CommandError` vocabulary; consent is a non-defaulted
  `confirmed:` parameter, so a caller that supplies none gets a `ConfirmationPrompt` describing what
  confirming entails. It presents nothing and imports no AppKit — a display leaves through the
  `surfaceDisplay` hook, an unawaited failure through `onFailure` — and `events()` vends an
  `AsyncStream<VMLibraryEvent>` fed by one diffing observation plus the clone/import copy failures
  no model field survives to hold, for callers that cannot observe the model. Whether a given VM
  admits a given command is derived in one place, `VMCapabilityCatalog`: every AppKit surface's
  enablement reads it, and so does every verb guard in the core save two deliberate ones in `stop`
  — it leads with the preparing refusal, and its `.force` disposition takes no state gate at all,
  because the states a force stop is most needed in are the ones no gate predicts. Clone and import
  register a preparing "phantom" `VMInstance` **synchronously, before any `await`** — that is what
  reserves the destination atomically on the MainActor, so overlapping imports and clones cannot
  claim the same bundle URL.
- `VMCommandEnvelopeRouter` — the wire boundary: decodes a `VMCommandRequest`, calls `VMCommanding`,
  encodes a `VMCommandResponse`. It depends on the protocol, never the concrete core.
- `VMIntentGateway` — the App Intents boundary, published through `AppDependencyManager` so every
  intent and both entity queries resolve the same one. Addresses VMs by `.id` alone (the entity
  carries the resolved identifier), and awaits the app's first library read before any verb or read,
  since an intent can be delivered while that read is still in flight. It presents nothing: a
  `CommandError` reaches Shortcuts through `CustomLocalizedStringResourceConvertible`, and consent is
  gathered by re-issuing the verb with `confirmed: true`. It also counts intents in flight and
  reports the process idle to `AppDelegate` when the last one finishes — the only signal a process
  the system launched to service an intent, and which therefore has no window, can settle on.
- `VMLibraryViewModel` — the AppKit adapter over `VMCommandCore` and `VMLibrary`. Runs no verb
  itself: each method shows the sheet a verb is owed, calls the facade with explicit consent, and
  routes the returned `CommandError` to a surface. It also owns the inline rename state and the
  settings edits the facade does not cover, forwards the library's reads so UI sees one
  surface, and drives alerts, sheets and the wizard by calling its `VMLibraryPresenting` delegate
  imperatively rather than toggling observed flags.
- `VMLifecycleCoordinator` — `@MainActor`; owns `VirtualizationService`, `MacOSInstallService`,
  `IPSWService`, `USBDeviceService`, and the Linux resolve/download seams (`LinuxImageResolving`,
  `Downloading`), and orchestrates the macOS install and Linux install pipelines, each driven by
  the install context persisted on `VMConfiguration` (`installContext` / `linuxInstallContext`)
  until it completes. It serializes lifecycle operations per VM; `stop` and `forceStop` deliberately
  bypass that serialization so a hung operation can always be cancelled.
- `VMCreationViewModel` — a pure `@Observable` state machine for the creation wizard, with no
  UI-framework dependency. Every image source is backed by an injected service protocol, so the
  wizard can name what a source will install before anything is downloaded.
- `VMDirectoryWatcher` — a `DispatchSource` on the VMs directory that triggers reconciliation in
  `VMLibrary` when the library changes on disk.

### Views

Pure AppKit throughout: `NSViewController`/`NSView` subclasses plus free `make*` atom factories,
observing `VMLibraryViewModel` and individual `VMInstance`s through the Observation framework —
usually the `observeRecurring` seam below, occasionally a hand-rolled `withObservationTracking`
re-arm loop. Content controllers decouple from the view model through delegate protocols; their
hosts implement the delegates and forward the user's choice on.

Constraints the file layout does not show:

- **No shared callout, form container, or base class.** Consistency comes from shared token sets
  (`CalloutStyle`, `GroupedFormStyle`, `Spacing`, `Typography`), not inheritance; genuinely
  shareable controllers are reused by init parameterization. The settings panels follow the same
  rule: `VMSettingsPanel` is a protocol with default hook bodies, and what they share beyond it is
  a context object and the form atoms.
- **The settings pane holds one surface at a time.** `VMOverviewResolver` answers, without views,
  everything the configuration cannot — host state, injected services, and three off-main reads —
  so the overview's cards need no panel to exist to state a figure, and the panel stating the same
  figure reads it there rather than resolving it again. A panel is built on the first drill-in and
  rebuilt when the VM under it moves.
- **Popover anchors target a wrapper `NSView`, never an inner control**, so
  `NSPopover.preferredEdge` is interpreted in an unflipped coordinate system.
- **The clipboard window renders inline RTF only, never HTML.**
- **`VZVirtualMachineView` is fed only through `VMDisplayHandle`** — the session's one `Sendable`
  crossing, handed to `VMDisplayBackingView` by the controllers that render a live VM. Every other
  view asks `VMInstance.hasLiveVirtualMachine` instead of reaching for the VM.

```
NSSplitViewController (MainWindowController)
├── Sidebar: SidebarViewController → NSOutlineView (source list) → SidebarVMRowCellView (per VM)
└── Detail:  DetailContainerViewController  (owns DetailAlertsPresenter)
    ├── VMDisplayBackingView (layered on top; VZVirtualMachineView + overlays)
    └── DetailEmptyStateView ⇆ VMDetailRouterViewController  (routes via DetailRoute.resolve)
            ├── VMSettingsViewController                    (stopped / running-settings; shell)
            │       ├── VMOverviewResolver                  (view-less; what both surfaces state)
            │       ├── VMSettingsOverviewViewController    (category cards ⇆ VMSettingsOverviewDelegate)
            │       └── VMSettings{General,System,Storage,Network,Sharing,Snapshots}PanelViewController
            │               (one per VMSettingsCategory, built on drill-in;
            │                VMSettingsPanel ⇆ VMSettingsPanelHost)
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
`SerialSocketRelay` (best-effort tee, gated on `serialSocketRelayEnabled`), whose `AF_UNIX` socket
is the sole host-side writer of serial input. There is no in-app terminal emulator — emulation is
delegated to the user's terminal.

### Data Flow

```
AppDelegate
    ├── creates → VMLibraryViewModel (AppKit adapter: sheets, consent, presentation)
    │                 ├── VMCommandCore (the verbs, headless; conforms to VMCommanding)
    │                 ├── VMLibrary (owns [VMInstance])
    │                 │      └── VMDirectoryWatcher, SystemSleepWatcher
    │                 ├── VMStorageService, VMSnapshotStore (one each, held by all three)
    │                 ├── DiskImageService
    │                 └── FileSystemOperating (trash/remove seam; also held by DownloadService)
    ├── creates → VMLifecycleCoordinator
    │                 ├── VirtualizationService
    │                 ├── MacOSInstallService
    │                 ├── IPSWService
    │                 └── USBDeviceService
    ├── creates → MainMenuController
    └── creates → AppWindowRegistry
                      ├── creates → MainWindowController (NSSplitViewController + NSToolbar)
                      ├── manages → ClipboardWindowController (per VM), SettingsWindowController
                      └── holds → VMDisplayPlacementController
                                      └── manages → VMDisplayWindowController (per VM)

AppKit views ──observe──→ VMLibraryViewModel ──forwards──→ VMLibrary (state, persistence)
                          VMLibraryViewModel ──calls────→ VMCommanding (VMCommandCore)
                          VMLibraryViewModel ──presents──→ VMLibraryPresenting (DetailContainerViewController)

A wire client ──bytes──→ VMCommandEnvelopeRouter ──calls──→ VMCommanding (same verbs, same refusals)

Siri / Shortcuts / Spotlight ──App Intents──→ VMIntentGateway ──calls──→ VMCommanding
                                              VMIntentGateway ──idle───→ AppDelegate

VMCommandCore ──reads/writes──→ VMLibrary
              ──delegates────→ VMLifecycleCoordinator ──→ Services
              ──emits────────→ AsyncStream<VMLibraryEvent>
```

### Utilities

- `ObservationLoop` — `observeRecurring(track:apply:)`, the standard observation seam. Returns a
  cancel token the caller stores; the loop stops when it deallocates.
- `PathValidation` — the shared resolve-symlinks → exists → type → permissions check for
  user-supplied paths.
- `NSWindowExtensions.withStableContentSize(_:styleMask:contentViewController:)` — the one place a
  window is built with an exact initial content size.
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

It also carries the VM command vocabulary — `VMSelector`, `VMVerb`, the result and refusal types,
and the `VMCommandRequest`/`VMCommandResponse` envelope — so an out-of-process client links the same
declarations the app throws and returns, rather than a mirror of them.

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
kernel resources until relaunch — hence one owner (`RuntimeFileAccess`, held by the session
context) and one release point (`VMSessionContext.tearDown`).

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

