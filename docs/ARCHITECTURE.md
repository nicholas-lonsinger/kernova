# Architecture

The map for a structural change — a new service, protocol or seam, a changed
data flow, a changed actor isolation: which type owns a behavior, and which
protocol joins it to its neighbors.

## Packages and targets

`KernovaCore/Package.swift` and `KernovaKit/Package.swift` explain each of
their targets, and each Xcode target explains itself in
`Config/Targets/<Target>.xcconfig`. The `KernovaCore` package is three layers:
the `KernovaCore` target, the core, which reaches neither AppKit nor
Virtualization (`Tools/check-core-imports.sh`); `KernovaVirtualization`, the
engine, over it; and `KernovaUI`, the AppKit layer, over both.

## Composition

`KernovaApp.main()` (`Kernova/App/`) is the composition root. It reads
`Bundle.main` once, into `AppBundleProducts`, builds the production services
and the `VMLibraryViewModel` over them, and hands that to `AppDelegate.init`,
which builds the App-layer owners (`KernovaCore/Sources/KernovaUI/App/`). What
those owners decide lives in the AppKit-free types of
`KernovaCore/Sources/KernovaCore/App/`. Every window controller builds its
window through a `WindowStage`, and that window goes on screen through the
`SessionFocus` the composition root builds.

## Front doors

Every verb is a `VMCommandCore` method; `VMAdmission` decides what a VM admits,
which `VMCapabilityCatalog` reads for every surface and `VMActivity` commits,
and `VMConfigurationKeyRegistry` names every configuration key. These surfaces
call the core and present its refusals in their own idiom; the out-of-process
ones open in `AppResidencyController.registerAutomationFrontDoors`:

- `VMLibraryViewModel` — the app's own UI, through `VMLibraryPresenting` and
  `LibraryWindowPresenting`.
- `VMCommandSocketListener` → `VMCommandEnvelopeRouter` — the `kernova` tool.
- `VMIntentGateway` — Shortcuts and Spotlight.
- `VMURLGateway` — `kernova:` links.
- `VMScriptingGateway` — Apple events.

## Models

`VMInstance` is the `@MainActor` runtime owner of one VM: it reads its state
off its `VMBundle`, and its `VMActivity` holds at most one `VMSessionContext`,
whose `VMSession` actor alone touches the `VZVirtualMachine`.

`VMBundle` holds a library bundle's committed state. It writes the state files
through `VMBundleFiles` over the `VMBundleFileAccessing` seam, the machine
files through `VMBundleMachineFileWorking`, and the firmware and platform files
through `VMPlatformFileWriting`, which the engine answers. `VMBundleLayout`
derives every in-bundle path. The library's own files persist apart from every
bundle, in `VMNetworkDirectory` and `VMOrganizationDirectory`, through
`CoordinatedJSONFile`.

A bundle a create, clone or import is still writing is a `VMStagedBundle`,
which `VMLibrary` lists as a `VMArrival`; a bundle no read can take is listed
as an `UnreadableVM`. The config check (`VMLibrary+ConfigCheck.swift`) reads
every persisted config file and repairs one no read can take.

## Services

- Engine: `ConfigurationBuilder` is the one `VZVirtualMachineConfiguration`
  translation. The core reaches the engine only through `VMSessionOperating`
  and the `Services/Protocols/` seams, whose engine implementations
  `KernovaApp` supplies.
- Network: `VmnetNetworkService` is process-wide; each session's
  `VMSessionContext` holds its `VmnetSessionNetworks` view of it and its
  `NetworkAttachmentCoordinator`.
- Agent hub: one `AgentHub` (KernovaKit's `KernovaAgentHost`) per `VMInstance`,
  to which each session with a socket device attaches its
  `VZGuestStreamTransport`. `VMInstance.agentPresentation` is what every
  agent-status surface reads, and one `ItemFeatureRouter` joins the hub to each
  item feature's owner: `HubClipboardService`, `HubDropService` and
  `HubDragOut`.
- Clipboard: `ClipboardServicing` unifies `HubClipboardService` (the guest
  agent) and `SpiceClipboardService` (the guest's SPICE agent) behind
  `VMInstance.clipboardService`, which `ClipboardRoute` picks.

## Views

`MainWindowController` hosts `SidebarViewController` and
`DetailContainerViewController`, whose detail side routes through
`VMDetailRouterViewController` on `DetailRoute`. A live display is
`VMDisplayBackingView`, fed only through `VMDisplayHandle`; it moves files both
ways through the `VMDisplayTransferHosting` its host resolves (`VMInstance`).

## Guest agents

The host and every agent share one protocol stack in KernovaKit.
`HostConnectionRuntime` drives it on the host and `PeerAgentRuntime` in an
agent, over the one `ByteStream`: `KernovaPlatformPOSIX`'s `POSIXByteStream`,
on the vsock socket an agent dials and the engine's `AgentListenerHost`
accepts. Calls into an OS live in its platform layer: `KernovaPlatformDarwin`
and `KernovaPlatformLinux`.

- The app links the `KernovaAgentHost` product through `KernovaCore`.
- `KernovaMacOSAgent` links `KernovaPlatformDarwin`, whose `MacAgentPeer` runs
  both the session peer and the system peer.
- `kernova-agent` is the `KernovaLinuxAgent` executable, whose `AgentShell`
  runs a `PeerAgentRuntime` over `KernovaPlatformLinux`.
