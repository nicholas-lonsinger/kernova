# Architecture

The map for a structural change — a new service, protocol or seam, a changed
data flow, a changed actor isolation: which type owns a behavior, and which
protocol joins it to its neighbors. Each type's contract is on its own `///`;
nothing here restates one.

## Composition

`AppDelegate.init` (`Kernova/App/`) is the composition root. It builds
`VMLibraryViewModel`, then `AppWindowRegistry` (holding
`VMDisplayPlacementController`), `AppResidencyController`, `MainMenuController`
and `AppTerminationController`. `AppDelegate.main()` is the one branch on
process mode, and the unit-test host takes the arm that builds none of it.

`VMLibraryViewModel.init` (`Kernova/ViewModels/`) builds everything beneath the
UI: `VMLifecycleCoordinator` over the services, `VMLibrary`,
`VMSleepWakeCoordinator`, `USBAccessoryCoordinator` and `VMCommandCore`. Each
`VMInstance` owns a `VMActivity`, the one writer of its lifecycle phase and live
session.

The seams between the App-layer owners are protocols: `AppLaunchHosting`,
`WindowResidencyHosting`, `SoftQuitHosting`, `MainMenuHosting`,
`VMDisplayPlacementHosting`, `DisplayBootGeometryProviding`.

## Front doors

Every verb is a `VMCommanding` method, implemented once by `VMCommandCore`
(`Kernova/Commands/`); `VMAdmission` decides what a VM admits, which
`VMCapabilityCatalog` reads for every surface and `VMActivity` commits, and
`VMConfigurationKeyRegistry` names every configuration key. Five surfaces call
the facade and present its refusals in their own idiom:

- `VMLibraryViewModel` — AppKit, through `VMLibraryPresenting`.
- `VMCommandSocketListener` → `VMCommandEnvelopeRouter` — the `kernova` tool,
  over the app-group `AF_UNIX` socket.
- `VMIntentGateway` (`Kernova/Intents/`) — Shortcuts and Spotlight.
- `VMURLGateway` (`Kernova/URLs/`) — `kernova:` links, from
  `application(_:open:)`.
- `VMScriptingGateway` (`Kernova/Scripting/`) — Apple events, through the
  delegate's `virtualMachines` element.

## Models (`Kernova/Models/`)

`VMConfiguration` (`config.json`), `VMHostState` (`host-state.json`),
`VMSnapshotManifest` (`Snapshots/manifest.json`) and `USBAccessoryPairingSet`
(`usb-accessories.json`) are what persists. `VMBundle` holds their committed
values and is the one reader and writer of those files, through
`VMBundleFiles` over the `VMBundleFileAccessing` seam
(`CoordinatedBundleFileAccess` in production); `VMLibrary` owns the policy a
configuration write passes on its way there. `VMBundle` is also the one writer
of the bundle's machine files, through the `VMBundleMachineFileWorking` seam
(`VMBundleMachineFiles` in production) that only `VMBundle.Factory` holds.
`VMInstance` is the `@MainActor`
runtime owner of one VM: it reads its state off its `VMBundle`, and its
`VMActivity` holds the lifecycle phase and at most one `VMSessionContext`,
whose `VMSession` actor alone touches the `VZVirtualMachine`. `VMLibrary`
lists a `VMArrival` beside its VMs for each create, clone or import still
writing its bundle, and turns every published bundle into a `VMInstance`
through `adopt`. `VMBundleLayout` derives every in-bundle path.

Guest-version floors: `GuestAgentDiskDelivery`, `GuestInputDevices`, and
`MacOSGuestProvisioning` each carry one `MacOSVersion` floor and read
`VMConfiguration.effectiveGuestMacOSVersion` of
`VMInstance.effectiveConfiguration`, the one source of a guest's version.

## Services (`Kernova/Services/`)

- VZ-facing: `ConfigurationBuilder` (the one `VZVirtualMachineConfiguration`
  translation), `VirtualizationService`, `MacOSInstallService`,
  `RemovableMediaDeviceService`, and `USBAccessoryService` (macOS 27; optional
  on `VMLifecycleCoordinator` — `nil` is the capability's absence).
- Network: `VmnetNetworkService` (process-wide), `NetworkAttachmentCoordinator`
  (one per session, held by `VMSessionContext`), and `GuestAddressObserver`
  (over `HostARPTableReader`) and `VMMACAddressRegistry`, sequenced by
  `VMLibrary`.
- Vsock, macOS guests: `KernovaVsockPort` and `VsockListenerHost`; per VM, a
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

## Views (`Kernova/Views/`)

`MainWindowController` (`Kernova/App/`) hosts `SidebarViewController` and
`DetailContainerViewController`; the detail side routes through
`VMDetailRouterViewController` on `DetailRoute`, and a live display is
`VMDisplayBackingView`, fed only through `VMDisplayHandle`.
`MainWindowController` and `VMDisplayWindowController` each build their
toolbar through a `VMToolbarManager`; `ClipboardToolbarButton` is the one
view-backed item.

## Shared package and helper targets

`KernovaKit/Package.swift` names every product and why each is shaped as it is.
`KernovaRelaunchHelper`, `KernovaCLI` (`kernova`), `KernovaMacOSAgent`
(`Kernova Guest Agent.app`) and `KernovaMacOSAgentTests` each explain
themselves in `Config/Targets/<Target>.xcconfig` and their entitlements file.
