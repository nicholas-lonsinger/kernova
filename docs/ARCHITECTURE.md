# Architecture

The map for a structural change — a new service, protocol or seam, a changed
data flow, a changed actor isolation: which type owns a behavior, and which
protocol joins it to its neighbors. Each type's contract is on its own `///`;
nothing here restates one.

## Composition

`KernovaApp.main()` (`Kernova/App/`) is the composition root. It reads
`Bundle.main` once, into `AppBundleProducts`, builds the production
services and the `VMLibraryViewModel` over them, and hands that to
`AppDelegate.init`, which builds `AppWindowRegistry` (holding
`VMDisplayPlacementController`), `AppAlertPresenter` (attached to the view
model before the library's first read), `AppResidencyController`,
`MainMenuController` and `AppTerminationController`.

What those owners decide lives in AppKit-free types they call:
`AppResidencyPolicy`, `VMDisplayPlacement`, `AlertQueue` and
`AppAlertConfigurations`, `AppMenuQuitItem`, and `WindowAutosave` (inside
`WindowStage`). `AppTerminationController` is AppKit-free itself; its
`+AppKit` extension supplies the quit Apple Event, the sender lookup and the
termination it ends.

The root also builds the one `AppPresence` those owners share. Every window
controller builds its window through a `WindowStage`; the test stage parks each
window beyond every display, and the sheets on it go up beside it.

`VMLibraryViewModel.init` (`KernovaCore/Sources/KernovaCore/ViewModels/`) builds everything beneath the
UI: `VMLifecycleCoordinator` over the services, `VMLibrary`,
`VMSleepWakeCoordinator`, `USBAccessoryCoordinator` and `VMCommandCore`. Each
`VMInstance` owns a `VMActivity`, the one writer of its lifecycle phase and live
session.

The seams between the App-layer owners are protocols: `AppLaunchHosting`,
`WindowResidencyHosting`, `SoftQuitHosting`, `VMDisplayPlacementHosting`.

## Front doors

Every verb is a `VMCommandCore` method (`KernovaCore/Sources/KernovaCore/Commands/`); `VMAdmission`
decides what a VM admits, which `VMCapabilityCatalog` reads for every surface
and `VMActivity` commits, and `VMConfigurationKeyRegistry` names every
configuration key. Five surfaces call the core and present its refusals in
their own idiom:

- `VMLibraryViewModel` — AppKit, through `VMLibraryPresenting` (alerts, which
  `AppAlertPresenter` shows on the window each is about) and
  `LibraryWindowPresenting` (the library window's own surfaces).
- `VMCommandSocketListener` → `VMCommandEnvelopeRouter` — the `kernova` tool,
  over the app-group `AF_UNIX` socket.
- `VMIntentGateway` (`KernovaCore/Sources/KernovaCore/Intents/`) — Shortcuts and Spotlight.
- `VMURLGateway` (`KernovaCore/Sources/KernovaCore/URLs/`) — `kernova:` links, from
  `application(_:open:)`.
- `VMScriptingGateway` (`KernovaCore/Sources/KernovaUI/Scripting/`) — Apple events, through the
  delegate's `virtualMachines` element.

## Models

`VMConfiguration` (`config.json`), `VMHostState` (`host-state.json`),
`VMSnapshotManifest` (`Snapshots/manifest.json`) and `USBAccessoryPairingSet`
(`usb-accessories.json`) are what persists in a bundle; the library's named
networks (`Networks.json`) and its smart groups, folders and tag definitions (`Organization.json`) persist apart
from every bundle, each file written only by its directory — `VMNetworkDirectory`
and `VMOrganizationDirectory` (`KernovaCore/Sources/KernovaCore/ViewModels/`), which `VMLibrary` owns,
both through `CoordinatedJSONFile`. `VMBundle` holds their committed
values and is the one writer of a library bundle's readable files, through
`VMBundleFiles` over the `VMBundleFileAccessing` seam
(`CoordinatedBundleFileAccess` in production); every write holds a
`VMEditPermit` that `VMActivity` mints on admission, and a configuration write
passes the policy `VMLibrary` builds every bundle with through `VMBundle.Factory`.
A bundle a create, clone or import is still writing is a `VMStagedBundle`,
minted only for a fresh path under the staging directory. `VMBundle` is also the one writer
of the bundle's machine files, through the `VMBundleMachineFileWorking` seam
(`VMBundleMachineFiles` in production) that only `VMBundle.Factory` holds; it
writes the firmware and platform files through `VMPlatformFileWriting`, which
the engine's `VirtualizationPlatformFiles` answers.
`VMInstance` is the `@MainActor`
runtime owner of one VM: it reads its state off its `VMBundle`, and its
`VMActivity` holds the lifecycle phase and at most one `VMSessionContext`,
whose `VMSession` actor alone touches the `VZVirtualMachine`. `VMLibrary`
lists a `VMArrival` beside its VMs for each create, clone or import still
writing its bundle, and turns every published bundle into a `VMInstance`
through `adopt`; a bundle no read can take is listed as an `UnreadableVM`
instead. Every config file decodes through one decoder whose collecting mode
(`ConfigFileDiagnosis`) yields an `UnreadableConfigFile`; the config check
(`VMLibrary+ConfigCheck.swift`) reads them all and rewrites a file no read can
take through `VMBundleFiles.repair` or `CoordinatedJSONFile.repair`.
`VMBundleLayout` derives every in-bundle path.

Guest-version floors: `GuestAgentDiskDelivery`, `GuestInputDevices`, and
`MacOSGuestProvisioning` each carry one `MacOSVersion` floor and read
`VMConfiguration.effectiveGuestMacOSVersion` of
`VMInstance.effectiveConfiguration`, the one source of a guest's version.

## Services

- VZ-facing, the engine (`KernovaVirtualization`): `ConfigurationBuilder` (the one
  `VZVirtualMachineConfiguration` translation), `VMSession`,
  `VirtualizationService`, `MacOSInstallService`, `USBAccessoryService` (macOS
  27; optional on `VMLifecycleCoordinator` — `nil` is the capability's
  absence) and `VirtualizationHost`. Code outside the
  engine and the AppKit layer reaches it only through `VMSessionOperating`,
  `VirtualizationHostProviding` and the `Services/Protocols/` seams, whose
  engine implementations `KernovaApp` builds.
- Network: `VmnetNetworkService` (process-wide) and the `VmnetSessionNetworks`
  view each session attaches through and `NetworkAttachmentCoordinator` (one
  of each per session, held by `VMSessionContext`), and `GuestAddressObserver`
  (over `HostARPTableReader`) and `VMMACAddressRegistry`, sequenced by
  `VMLibrary`.
- Vsock, macOS guests: `KernovaVsockPort` and `VsockListener`, which the
  session hosts as a `VsockListenerHost`; per VM, a
  `VsockAdmissionGate` and two `VsockDataConnectionSink`s held by `VMInstance`;
  per session, `VsockFeatureCoordinator` (held by `VMSessionContext`) over
  `VsockFeatureDescriptor.all` — `VsockControlService`, `VsockGuestLogService`,
  `VsockClipboardService`, `VsockDropService`.
- Clipboard: `ClipboardServicing` unifies `VsockClipboardService` and
  `SpiceClipboardService` (Linux) behind `VMInstance.clipboardService`;
  `HostClipboardPublisher` and `ClipboardPassthroughCoordinator` write the host
  pasteboard; the engine both host services and both guest agents drive is
  KernovaKit's `ClipboardEndpoint`.
- Sockets: `UnixSocketListener` under `SerialSocketRelay` and
  `VMCommandSocketListener`.

## Views

`MainWindowController` (`KernovaCore/Sources/KernovaUI/App/`) hosts `SidebarViewController` and
`DetailContainerViewController`; the detail side routes through
`VMDetailRouterViewController` on `DetailRoute`, and a live display is
`VMDisplayBackingView`, fed only through `VMDisplayHandle`; it moves files both
ways through the `VMDisplayTransferHosting` its host resolves (`VMInstance`).
`MainWindowController` and `VMDisplayWindowController` each build their
toolbar through a `VMToolbarManager`; `ClipboardToolbarButton` is the one
view-backed item.

## Shared package and helper targets

`KernovaKit/Package.swift` names every product and why each is shaped as it is.
`KernovaCore` (`KernovaCore/`) holds app code that needs neither AppKit nor
Virtualization; the app links it and reaches its `package` declarations. Its
`KernovaVirtualization` target is
the engine, over the core, and its `KernovaUI` target is the AppKit layer; the
app links both.
`KernovaRelaunchHelper`, `KernovaCLI` (`kernova`), `KernovaMacOSAgent`
(`Kernova Guest Agent.app`), `KernovaMacOSAgentTests`, `KernovaTestHost`,
`KernovaUITests` and `KernovaAppBundleTests` each explain
themselves in `Config/Targets/<Target>.xcconfig` and their entitlements file.
