# Architecture

## Overview

Kernova is a macOS application for creating and managing virtual machines via Apple's Virtualization.framework, supporting both macOS and Linux guests. It is built as a pure-AppKit app (the app target no longer imports SwiftUI), targeting macOS 26 (Tahoe) with Swift 6 strict concurrency. The app target uses only Apple system frameworks; the lone package dependency is Apple-published `swift-protobuf`, consumed by the local `KernovaProtocol` package (see [Dependencies](#dependencies)).

## Directory Structure

Each entry carries a one-line role; behavioral detail lives in the [Component Map](#component-map) below.

```
Kernova/
├── App/                                # App lifecycle and window management
│   ├── AppDelegate.swift               # NSApplicationDelegate — startup, window tracking, menus, suspend-on-quit, TCC relaunch
│   ├── MainWindowController.swift      # Main window: NSSplitViewController + native NSToolbar
│   ├── VMDisplayWindowController.swift # Per-VM display window (pop-out or fullscreen), auto-closes on VM stop
│   ├── DetailContainerViewController.swift # Detail-pane host — layers the VM display over detail content; owns DetailAlertsPresenter; implements VMLibraryPresenting
│   ├── VMToolbarManager.swift          # Shared toolbar logic for lifecycle, suspend, display, and settings-toggle items
│   ├── ClipboardWindowController.swift # Per-VM clipboard sharing window, auto-closes on VM stop
│   ├── ClipboardContentViewController.swift # Pure-AppKit clipboard text editor + status bar
│   └── Info.plist                      # App configuration and metadata
├── Models/                             # Data types — all value types or @MainActor-isolated
│   ├── VMConfiguration.swift           # Codable/Sendable struct persisted as config.json per VM bundle
│   ├── VMInstance.swift                # @Observable runtime wrapper: VMConfiguration + VZVirtualMachine + VMStatus
│   ├── VMBundleLayout.swift            # Sendable struct centralizing bundle file paths + live disk sizing
│   ├── StorageDisk.swift               # StorageDisk + StorageDiskKind (.virtio/.usbMassStorage) + RemovableMediaItem
│   ├── USBDeviceInfo.swift             # Runtime metadata for an attached USB mass-storage device
│   ├── MacOSInstallContext.swift       # Persisted macOS IPSW install intent: source, paths, fresh-download flag
│   ├── MacOSInstallState.swift         # Tracks two-phase macOS installation progress (download + install)
│   ├── VMStatus.swift                  # Enum: stopped, starting, running, paused, saving, restoring, installing, error
│   ├── VMBootMode.swift                # Enum: macOS, efi, linuxKernel
│   ├── VMGuestOS.swift                 # Enum: macOS, linux
│   └── KernovaUTType.swift             # UTType declaration for the .kernova bundle
├── Services/                           # Business logic — stateless or @MainActor
│   ├── ConfigurationBuilder.swift      # VMConfiguration → VZVirtualMachineConfiguration (3 boot paths)
│   ├── VirtualizationService.swift     # VM lifecycle: start/stop/pause/resume/save/restore (@MainActor)
│   ├── VMStorageService.swift          # CRUD for VM bundles + cloning (Sendable struct)
│   ├── DiskImageService.swift          # Creates ASIF disk images from bundled templates (Sendable struct)
│   ├── MacOSInstallService.swift       # Drives macOS guest install via VZMacOSInstaller (@MainActor)
│   ├── IPSWService.swift               # Fetches/downloads macOS restore images with streamed, resumable HTTP (Sendable final class)
│   ├── USBDeviceService.swift          # Runtime USB mass-storage attach/detach against the live VM's XHCI controller
│   ├── SystemSleepWatcher.swift        # Observes system sleep/wake, triggers VM pause/resume
│   ├── AttachmentFileMonitor.swift     # Reactive existence tracker for external attachments (@MainActor, @Observable)
│   ├── SerialSocketRelay.swift         # Host-side AF_UNIX listener exposing the serial port to an external terminal
│   ├── SpiceAgentProtocol.swift        # SPICE agent wire format: VDI chunks, message headers, clipboard types
│   ├── SpiceClipboardService.swift     # Linux clipboard: pipe I/O, SPICE protocol state machine (@MainActor)
│   ├── ClipboardServicing.swift        # Protocol shared by the SPICE + vsock clipboard implementations
│   ├── VsockClipboardService.swift     # macOS clipboard: vsock offer/request/data state machine (@MainActor)
│   ├── VsockControlService.swift       # macOS always-on control channel: Hello + heartbeat liveness, owns AgentStatus (@MainActor, @Observable)
│   ├── VsockGuestLogService.swift      # Consumes guest LogRecord frames, forwards to os.Logger (@MainActor)
│   ├── VsockListenerHost.swift         # @MainActor wrapper binding a VZVirtioSocketListener to one vsock port
│   ├── VsockPorts.swift                # Central registry of host-side vsock port assignments
│   ├── AgentStatus.swift               # Guest-agent install/version/liveness enum driving sidebar + clipboard-window affordances
│   ├── KernovaGuestAgentInfo.swift     # Bundled guest agent version + installer DMG URL accessors
│   └── Protocols/                      # Service protocol abstractions for DI and testing
│       ├── VirtualizationProviding.swift
│       ├── VMStorageProviding.swift
│       ├── DiskImageProviding.swift
│       ├── MacOSInstallProviding.swift
│       ├── IPSWProviding.swift
│       └── USBDeviceProviding.swift
├── ViewModels/                         # Observable view models and coordinators
│   ├── VMLibraryViewModel.swift        # Central view model — owns [VMInstance]; presents via the VMLibraryPresenting delegate
│   ├── VMLibraryPresenting.swift       # Presentation delegate protocol (implemented by DetailContainerViewController)
│   ├── VMLifecycleCoordinator.swift    # Owns services, orchestrates multi-step ops, serializes per-VM operations (@MainActor)
│   ├── VMCreationViewModel.swift       # Drives the multi-step VM creation wizard
│   └── VMDirectoryWatcher.swift        # DispatchSource monitor for external filesystem changes
├── Views/                              # Pure-AppKit NSViewControllers / NSViews
│   ├── VMInstance+Display.swift        # Display-layer extension: status display names/colors, cold- vs live-paused distinction
│   ├── Sidebar/
│   │   ├── SidebarViewController.swift # Source-list NSOutlineView: selection, double-click-to-start, context menu, inline rename, drag-reorder + bundle import
│   │   ├── SidebarVMRowCellView.swift  # Leaf-row cell: state-tinted OS icon / busy spinner, name, agent accessory, inline-rename editor
│   │   ├── SidebarGroupHeaderCellView.swift # Group-row cell rendering a section title
│   │   ├── SidebarSection.swift        # Outline section model (single .virtualMachines today; a second group is a localized addition)
│   │   ├── SidebarAgentStatusButtonView.swift # Agent-status accessory: SF-Symbol button or spinner + status-popover anchor
│   │   └── AgentStatusPopoverContentViewController.swift # Agent-status popover: per-status copy + install/update/reinstall actions
│   ├── Detail/
│   │   ├── VMDetailRouterViewController.swift # Resolves a DetailRoute from VM status and swaps its reused child VCs
│   │   ├── DetailRoute.swift           # Pure routing enum + DetailRoute.resolve(...) mapping (unit-tested)
│   │   ├── VMSettingsViewController.swift # VM configuration editor — 9 grouped-form sections
│   │   ├── DetailStatusPlaceholderViewController.swift # Centered spinner + label for transient states and clone/import preparing
│   │   ├── InitialBootBannerView.swift # Orange "Initial Boot" banner stacked above settings for not-yet-booted macOS VMs
│   │   ├── DetailEmptyStateView.swift  # "No Virtual Machine Selected" empty state with a New VM button
│   │   ├── MacOSInstallProgressViewController.swift # Two-step (download → install) progress UI
│   │   ├── MicPermissionPresentation.swift # Pure helpers: mic-permission warning mapping, external attachment paths (unit-tested)
│   │   ├── DiskSizePopoverCoordinator.swift # Owns the disk-size PopoverPresenter; forwards the confirmed size to onConfirm
│   │   ├── DiskSizePopoverContentViewController.swift # Generic "pick a disk size and confirm/cancel" popover content
│   │   ├── StorageDiskReorderSheetContentViewController.swift # Boot Order sheet: drag-reorderable disk table
│   │   ├── AttachmentRowView.swift     # One attachment row (storage disk or removable medium)
│   │   ├── StorageDiskSubtitle.swift   # Off-main live disk-size subtitle reads + label fill-in
│   │   ├── AttachmentSubtitleLabel.swift # Caption label factory with red "Missing — " prefix for absent files
│   │   ├── AttachmentIconButton.swift  # Leading-icon control: SF Symbol, or red triangle + missing-file popover
│   │   ├── AttachmentInfoPopoverContentViewController.swift # "Get Info" popover for attachment rows (value-snapshot init)
│   │   ├── MissingAttachmentPopoverContentViewController.swift # Missing-file popover: header + body + wrapped path
│   │   ├── CalloutStyle.swift          # Callout-popover design tokens + atom factories (headline/body/code)
│   │   ├── InfoButtonView.swift        # info.circle button wrapper showing InfoPopoverContentViewController on click
│   │   ├── InfoPopoverContentViewController.swift # Generic info popover taking [.body|.code] paragraphs
│   │   ├── MicrophonePermissionPopoverContentViewController.swift # Mic-permission warning popover with numbered bold-run steps
│   │   └── DeleteVMSheetContentViewController.swift # Unified Delete-VM confirmation sheet
│   ├── Shared/
│   │   ├── GroupedFormStyle.swift      # Grouped-form design atoms shared by the wizard and settings pane
│   │   └── DiskSizeMenuTitle.swift     # Tab-stop-aligned disk-size menu titles (right-aligned number, left-aligned unit)
│   ├── Console/
│   │   ├── VMDisplayPlaceholderContentViewController.swift # Detail-pane placeholder for non-inline display states
│   │   └── VMDisplayBackingView.swift  # Pure-AppKit VM display with pause/transition overlays
│   └── Creation/                       # Pure AppKit — every wizard step is an NSViewController
│       ├── VMCreationWizardViewController.swift # Shell: step indicator + swappable child step VCs + nav bar
│       ├── OSSelectionContentViewController.swift   # Step 1: choose macOS or Linux
│       ├── IPSWSelectionContentViewController.swift # Step 2 (macOS): IPSW source, path badge, overwrite/resume banners
│       ├── BootConfigContentViewController.swift    # Step 2 (Linux): EFI/kernel segmented control + file pickers
│       ├── ResourceConfigContentViewController.swift # Step 3: name, CPU/memory steppers, disk popup, networking
│       ├── ReviewContentViewController.swift   # Step 4: read-only summary + start-after-create switch
│       ├── WizardStepIndicatorView.swift # Dotted step-progress bar
│       └── WizardStyle.swift           # Scoped design tokens + make* atom factories for the wizard
├── Utilities/
│   ├── DataFormatters.swift            # Human-readable formatting for bytes, CPU counts, etc.
│   ├── UniqueName.swift                # Collision-free name generation (disk labels, clone names)
│   ├── PathValidation.swift            # Shared path validation: resolve symlinks, check existence/type/permissions
│   ├── InlineRenameSizing.swift        # Text-hugging sizing for inline-rename field editors
│   ├── NSImageExtensions.swift         # Nil-safe SF Symbol image loading
│   ├── NSViewExtensions.swift          # Full-size subview constraint helper
│   ├── NSOpenPanelExtensions.swift     # Pre-configured NSOpenPanel factory for browsing disk images
│   ├── DesignTokens.swift              # Spacing scale, StatusColor palette, shared Typography token
│   ├── ObservationLoop.swift           # observeRecurring(track:apply:) wrapper around withObservationTracking
│   ├── PopoverPresenter.swift          # NSPopover lifecycle wrapper (one per anchor, refresh-in-place, onClose)
│   ├── SheetPresenter.swift            # Custom-content sheet lifecycle wrapper around beginSheet
│   ├── SheetAlert.swift                # NSAlert presenter: AlertConfiguration + button roles → key-equivalents
│   └── DetailAlertsPresenter.swift     # Serialized presenter for detail-pane lifecycle alerts + delete sheet
└── Resources/
    ├── Assets.xcassets/                # App icons and image assets
    └── Kernova.entitlements            # com.apple.security.virtualization entitlement

DiskTemplates/                          # Bundled ASIF disk image templates (lzfse-compressed),
                                        # decompressed at VM creation time by DiskImageService

KernovaRelaunchHelper/
└── main.swift                          # Lightweight CLI watchdog for TCC-forced restarts

KernovaGuestAgent/                      # Guest-side vsock agent for macOS VMs + DMG packaging resources
├── main.swift                          # Entry point: signal handling, starts control + log + clipboard agents
├── VsockGuestClient.swift              # Generic connect/retry/serve loop shared by all three agents
├── VsockGuestControlAgent.swift        # Always-on control agent: Hello + heartbeat + PolicyUpdate handling
├── VsockHostConnection.swift           # Log-forwarding agent (ring buffer + flush over vsock)
├── VsockGuestClipboardAgent.swift      # Clipboard sync agent (pasteboard polling + offer/request/data)
├── VsockPorts.swift                    # Guest-side port registry (mirrors Kernova/Services/VsockPorts.swift)
├── VsockLogBridge.swift                # Static handle so KernovaLogger can hand records to VsockHostConnection
├── KernovaLogger.swift                 # Drop-in os.Logger wrapper that mirrors records to the host
├── KernovaLogMessage.swift             # Custom interpolation supporting OSLogPrivacy-shaped privacy attrs
├── Info.plist                          # Explicit Info.plist with preprocessor macro for CFBundleVersion
├── install.command                     # Guest-side installer: copies binary, registers LaunchAgent
├── uninstall.command                   # Guest-side uninstaller: stops agent, removes files
└── com.kernova.agent.plist             # LaunchAgent template (__INSTALL_DIR__ replaced at install time)

KernovaProtocol/                        # SPM package: extensible vsock wire protocol shared host <-> guest
├── Package.swift                       # Swift 6 package, depends on apple/swift-protobuf
├── Proto/
│   └── kernova.proto                   # Frame envelope + Hello/Error/Heartbeat + policy, clipboard, and log payloads
├── Sources/KernovaProtocol/
│   ├── Generated/
│   │   └── kernova.pb.swift            # Generated by Tools/regen-proto.sh — do not edit
│   ├── VsockFrame.swift                # Length-prefixed framing codec (4-byte BE prefix, 16 MiB cap)
│   └── VsockChannel.swift              # Bidirectional channel: framed reads/writes on a SOCK_STREAM fd
└── Tests/KernovaProtocolTests/
    ├── VsockFrameTests.swift           # Framing encode/decode + split/oversize/empty cases
    └── VsockChannelTests.swift         # Round-trip + EOF + close cases via socketpair(AF_UNIX)

Tools/
└── regen-proto.sh                      # Regenerates kernova.pb.swift via protoc + protoc-gen-swift

KernovaTests/
├── Mocks/                              # Protocol-conforming mocks with call counting + error injection
│   ├── MockVirtualizationService.swift
│   ├── SuspendingMockVirtualizationService.swift # Suspends mid-operation to test per-VM serialization
│   ├── MockVMStorageService.swift
│   ├── MockDiskImageService.swift
│   ├── MockMacOSInstallService.swift
│   ├── MockIPSWService.swift
│   ├── MockUSBDeviceService.swift
│   ├── SuspendingMockUSBDeviceService.swift # Suspends mid-operation to test the installer-mount mutex
│   └── MockVMLibraryPresenting.swift   # Records presentation requests for test assertions
├── TestHelpers.swift                   # Shared factories (makeInstance, …), waitUntil, event-driven AsyncGate
├── AgentStatusTests.swift              # AgentStatus synthesis pure-function tests
├── AttachmentFileMonitorTests.swift    # Attachment file existence monitoring and probing
├── BootConfigContentViewControllerTests.swift # Boot-mode selection UI + kernel command line
├── CalloutStyleTests.swift             # Token math + headline/body factory configuration
├── ConfigurationBuilderTests.swift     # VZ translation: boot paths, devices, path validation, storage topology
├── DataFormattersTests.swift           # Formatting utilities
├── DeleteVMSheetContentViewControllerTests.swift # Delete-sheet sections, checkbox locking rules, delegate flows
├── DetailRouteTests.swift              # Detail route resolution: install, settings, preparing states
├── DiskSizePopoverContentViewControllerTests.swift # Popup population, defaults, delegate firing
├── IPSWBundleTests.swift               # .kernovadownload bundle resume-URL + fresh-download layout
├── IPSWSelectionContentViewControllerTests.swift # IPSW source selection, destination, overwrite warning UI
├── IPSWServiceDownloadTests.swift      # Full HTTP download flow against a stub: fresh, resume, file-changed, 416
├── InfoPopoverContentViewControllerTests.swift # Paragraph rendering, fitting size, code paragraphs
├── MacOSInstallContextTests.swift      # Codec round-trip + backward-compat for the persisted install context
├── MacOSInstallStateTests.swift        # Install phase tracking
├── MicPermissionPresentationTests.swift # Mic-permission status → presentation mapping
├── MicrophonePermissionPopoverContentViewControllerTests.swift # Layout, bold step runs, non-selectable bodies
├── MissingAttachmentPopoverContentViewControllerTests.swift # Layout, fitting size, header + path label
├── NSImageExtensionsTests.swift        # SF Symbol loading utility
├── ObservationLoopTests.swift          # Observation re-registration + cancel-token behavior
├── OSSelectionContentViewControllerTests.swift # OS card selection + model binding
├── PathValidationTests.swift           # Resolve/symlink/existence/type/permission checks
├── PopoverPresenterTests.swift         # Lifecycle: initial state, idempotent close, onClose-on-delegate
├── ResourceConfigContentViewControllerTests.swift # Name/CPU/memory stepper bounds + disk popup
├── ReviewContentViewControllerTests.swift # Review-step display incl. macOS IPSW handling
├── SerialSocketRelayTests.swift        # AF_UNIX relay: tee, client input, supersede, reconnect, unlink, guards
├── SheetAlertTests.swift               # Role → NSButton config mapping + response dispatch
├── SheetPresenterTests.swift           # Lifecycle (show() untested — needs key window + run loop)
├── SidebarViewControllerTests.swift    # Status-dot color, agent-indicator gating, drag-reorder, context menu
├── SpiceAgentProtocolTests.swift       # SPICE wire format serialization + incremental parsing
├── SpiceClipboardServiceTests.swift    # SPICE clipboard message parsing + capabilities
├── StorageDiskReorderSheetContentViewControllerTests.swift # Boot Order rows, performReorder index math, delegate
├── StorageDiskSubtitleTests.swift      # Live disk-size subtitle reads from real on-disk files (ASIF, raw, missing)
├── USBDeviceServiceTests.swift         # USB device info model + attach/detach recording
├── VMBootModeTests.swift               # Boot mode enum
├── VMBundleLayoutTests.swift           # Bundle path derivation + ASIF capacity parsing (shdw header, overflow guards)
├── VMConfigurationTests.swift          # Encoding/decoding, defaults, migrations, storage lists, live-editable fields
├── VMConfigurationCloneTests.swift     # Clone-specific behavior (ID regeneration, clone-name generation)
├── VMCreationViewModelTests.swift      # All wizard steps, validation, OS-specific paths
├── VMCreationWizardViewControllerTests.swift # Wizard chrome, navigation, Next/Back/Create button states
├── VMGuestOSTests.swift                # Guest OS enum
├── VMInstanceTests.swift               # Status transitions, bundle layout, preparing state, agent watchdog
├── VMLibraryViewModelTests.swift       # List ops, selection, phantom rows, reconcile, delete fan-out, updateConfiguration
├── VMLifecycleCoordinatorTests.swift   # Orchestration, error handling, per-VM serialization, stop bypass
├── VMSettingsViewControllerTests.swift # Delete-confirmation prompts + control bindings
├── VMStatusTests.swift                 # Status enum behavior incl. canForceStop
├── VMStorageServiceTests.swift         # Storage CRUD + cloning
├── VMToolbarManagerTests.swift         # Toolbar item creation, state updates, label toggling
├── VirtualizationServiceTests.swift    # VM lifecycle operations via mock VZ objects
├── VsockClipboardServiceTests.swift    # Offer dedup, generations, stale-drop, inbound population
├── VsockControlServiceTests.swift      # Hello/heartbeat/liveness/policy + version comparison
└── VsockGuestLogServiceTests.swift     # Channel setup, log-frame parsing, record emission

KernovaGuestAgentTests/                 # Unit tests for the guest agent (standalone xctest bundle — no TEST_HOST;
│                                       # compiles the agent sources directly — see Helper Targets)
├── TestHelpers.swift                   # Socket-pair factories, waitUntil, AsyncGate, nextFrame, frame factories
├── KernovaLogMessageTests.swift        # Privacy-redaction matrix for KernovaLogMessage interpolations
├── VsockHostConnectionTests.swift      # Log ring-buffer cap, partial-flush re-enqueue, live-channel forwarding
├── VsockGuestClientTests.swift         # Connect/retry/stop lifecycle, socket-factory injection, pause/resume
├── VsockGuestClipboardAgentTests.swift # Echo suppression, reconnect reset, offer/request/data flow, setEnabled
└── VsockGuestControlAgentTests.swift   # Hello on connect, heartbeat cadence, reconnect, PolicyUpdate → onPolicy
```

## Component Map

### App Layer

**Files:** `AppDelegate.swift`, `MainWindowController.swift`, `DetailContainerViewController.swift`, `VMDisplayWindowController.swift`, `VMToolbarManager.swift`, `ClipboardWindowController.swift`, `ClipboardContentViewController.swift`

`AppDelegate` is the entry point. It creates the `VMLibraryViewModel` and `VMLifecycleCoordinator`, opens the main window, and manages the lifecycle of all windows. It tracks window controllers in dictionaries keyed by VM UUID, enabling one-to-many relationships (a VM can have a main view, a fullscreen window, and a clipboard window open simultaneously). `AppDelegate` also handles:

- The application menu (including VM-specific actions, Force Stop with `canForceStop` validation, and Window > Show Library with Cmd+0)
- Suspend-on-quit behavior (suspending VMs before termination)
- Conditional termination: `applicationShouldTerminateAfterLastWindowClosed` returns `false` when VMs are active or fullscreen windows exist, preventing premature exit on fullscreen-to-inline transitions
- Dock icon reopen: `applicationShouldHandleReopen` restores the main window when clicked with no visible windows, or when clicked while the app is already active and the library window has been closed
- Fullscreen exit recovery: closing a fullscreen window automatically re-shows the main library window via `showLibrary(_:)`
- TCC relaunch: when macOS force-quits the app for a TCC permission change while VMs are running, `applicationShouldTerminate` launches `KernovaRelaunchHelper` (a CLI embedded in `Contents/MacOS/`) before beginning the async VM save. The helper monitors the app's PID via `DispatchSource` and relaunches the app via `NSWorkspace` after it exits, working around macOS's TCC relaunch timeout. TCC is positively identified by intercepting the `kAEQuitApplication` Apple Event and checking if the sender is the Privacy & Security settings extension (`com.apple.settings.PrivacySecurity.extension`).

`MainWindowController` creates an `NSWindow` with an `NSSplitViewController` as the content view controller. The split view has two panes: a sidebar (`NSSplitViewItem(sidebarWithViewController:)` wrapping the pure-AppKit `SidebarViewController` — a source-list `NSOutlineView`) and a detail pane (`DetailContainerViewController`, which hosts the AppKit empty-state ⇆ `VMDetailRouterViewController`). An `NSToolbar` with native `NSToolbarItem`s provides lifecycle controls (Start/Resume, Pause, Stop), Suspend, Fullscreen, New VM, and a Show/Hide Settings toggle that lets the user view the (read-only) settings form while a VM is running. Shared toolbar items (lifecycle, suspend, display, settings toggle) are managed by `VMToolbarManager`; the New VM button and sidebar items remain controller-specific. The settings toggle only appears in the main window — the pop-out display window passes `settingsToggleID: nil`. Toolbar state is observed via `withObservationTracking` and items are validated through `NSToolbarItemValidation`. The `.fullSizeContentView` style mask and `.sidebarTrackingSeparator` preserve the full-height sidebar appearance matching Mail/Finder. The split view controller is a `SnapToFitSplitViewController` subclass that overrides `constrainSplitPosition` to magnetically snap the sidebar divider to the width that fully shows the longest VM name (computed by `SidebarViewController.widthToFitLongestRow()` from `SidebarVMRowCellView.contentWidth(forName:showsAgentAccessory:)`), clamped to the sidebar's `minimumThickness`/`maximumThickness` — the way Finder snaps its sidebar to the longest item.

`DetailContainerViewController` layers the AppKit VM display (`VMDisplayBackingView`) over the AppKit detail content (empty-state view ⇆ `VMDetailRouterViewController`), respecting each instance's `detailPaneMode`. It owns `DetailAlertsPresenter` and conforms to `VMLibraryPresenting` (the view model's presentation delegate), forwarding lifecycle alerts to the presenter and presenting the creation-wizard sheet via `SheetPresenter`.

### Models

**Files:** `VMConfiguration.swift`, `VMInstance.swift`, `VMBundleLayout.swift`, `StorageDisk.swift`, `USBDeviceInfo.swift`, `MacOSInstallContext.swift`, `MacOSInstallState.swift`, `VMStatus.swift`, `VMBootMode.swift`, `VMGuestOS.swift`, `KernovaUTType.swift`

The model layer has two key types:

- **`VMConfiguration`** is the persisted identity of a VM. It's a `Codable` + `Sendable` struct written as `config.json` inside each VM bundle. It holds: name, UUID, guest OS type, boot mode, CPU/memory/disk settings, display configuration (including `lastFullscreenDisplayID` for remembering which display a VM was fullscreen on), network settings, audio settings (`microphoneEnabled` — opt-in host microphone passthrough, defaults to off), guest agent state (`agentLogForwardingEnabled` for the opt-in vsock log fan-in, and `lastSeenAgentVersion` — the most recent guest-reported `Hello.agent_info.agent_version`, used to suppress the install nudge on stopped VMs whose agent has previously connected and to arm the post-start "didn't reconnect" watchdog), and OS-specific fields (macOS hardware model data, Linux kernel/initrd/cmdline paths).

- **`VMInstance`** is the runtime representation. It's an `@Observable` `@MainActor` class that wraps a `VMConfiguration`, an optional `VZVirtualMachine`, and a `VMStatus`. It references the VM's bundle path and provides computed properties for disk image, aux storage, and save file locations via `VMBundleLayout`. A view-layer extension (`VMInstance+Display.swift`) provides display properties (`statusDisplayName`, `statusDisplayColor`, `statusToolTip`) that distinguish preparing VMs (shown as "Cloning…"/"Importing…" in orange with a spinner), cold-paused VMs (state saved to disk, shown as "Suspended" in orange), and live-paused VMs (in memory, shown as "Paused" in yellow). The `PreparingOperation` enum (`.cloning`, `.importing`) provides display labels, cancel labels, and alert titles for preparing states. The `PreparingState` struct bundles the operation and its cancellable task into a single optional (`preparingState`) — when non-nil the instance is preparing, and `isPreparing` is a computed convenience. A per-instance `detailPaneMode` (enum `DetailPaneMode { case display, settings }`, defaulting to `.display`) lets the user toggle, while the VM is running, between the live display and a read-only view of the settings form; the mode is ignored when the VM is stopped (settings are always shown then). For macOS guests, `VMInstance` also owns a one-shot post-start watchdog: `startAgentPostStartWatchdog(grace:)` (kicked from `VirtualizationService.start` once status reaches `.running`) waits for the grace period (default 120 s) and flips `agentExpectedButMissing = true` if no guest agent `Hello` arrived in that window; the flag is cleared by `recordObservedAgentVersion(_:)` (called via the `VsockControlService` `onAgentVersionObserved` callback) and by `tearDownSession`. `VMInstance.agentStatus` synthesizes the `.expectedMissing(expected:)` case from `agentExpectedButMissing` + `configuration.lastSeenAgentVersion` so the rest of the UI sees the case alongside live `VsockControlService`-sourced states. Configuration mutations driven by guest activity (e.g. persisting a new `lastSeenAgentVersion`) flow through the `onUpdateConfiguration` closure, which `VMLibraryViewModel` wires to its centralized `updateConfiguration(of:mutate:)` dispatcher at every instance-construction site — so guest-driven and user-driven mutations share one persist + apply-live-policy path. The runtime list of currently-attached USB mass storage devices (whether sourced from `removableMedia` at cold start or from later XHCI hot-attaches) lives on `VMInstance.liveRemovableMedia: [USBDeviceInfo]`, which the reconcile flow keeps in sync with the actual VZ device list.

`VMBundleLayout` is a `Sendable` struct that takes a bundle root path and provides all derived file paths (disk image, aux storage, save file, serial log, etc.), keeping path logic centralized. `diskURL(forRelativePath:isInternal:)` is the single internal-vs-external path-to-URL rule. It also owns **live disk sizing**: `diskSizes(forRelativePath:isInternal:)` returns the on-disk footprint (`totalFileAllocatedSize`) *and* the virtual capacity in one coalesced read — capacity parsed from an ASIF's `shdw` header (offset 0x30, big-endian 512-byte sector count; magic-validated, bounds-checked, and **checked**-multiplied ×512 so a corrupt count degrades to nil rather than wrapping), or the logical file size for a non-ASIF (raw `.img`/`.iso`/`.dmg`). `diskOnDiskBytes`/`diskCapacityBytes` remain as thin accessors over the same read. All reads are live, never cached — a size can change out-of-band (e.g. a CLI resize), so any stored copy would go stale.

`StorageDisk` (with `StorageDiskKind`: `.virtio` / `.usbMassStorage`) and `RemovableMediaItem` model the two attachment lists — see [Storage topology](#storage-topology-mirrors-vz) below. `StorageDisk.uniqueLabel(base:existingLabels:)` generates collision-free default labels. `USBDeviceInfo` is the runtime metadata for an attached USB mass-storage device (id, path, read-only flag, attach date). `MacOSInstallContext` persists the macOS IPSW install intent (source, paths, fresh-download flag).

The remaining models are enums: `VMStatus` (stopped/starting/running/paused/saving/restoring/installing/error), `VMBootMode` (macOS/efi/linuxKernel), `VMGuestOS` (macOS/linux), and `MacOSInstallState` (tracking download and install phases with progress). `VMStatus` provides computed properties for state checks (`canStart`, `canStop`, `canForceStop`, `canPause`, `canResume`, `canSave`, `canEditSettings`, `canRename`, `isTransitioning`, `isActive`). `canForceStop` covers all states where a `VZVirtualMachine` may exist and need forceful termination (running, paused, starting, saving, restoring).

### Services

**Files:** `ConfigurationBuilder.swift`, `VirtualizationService.swift`, `VMStorageService.swift`, `DiskImageService.swift`, `MacOSInstallService.swift`, `IPSWService.swift`, `USBDeviceService.swift`, `SystemSleepWatcher.swift`, `AttachmentFileMonitor.swift`, `SerialSocketRelay.swift`, `SpiceAgentProtocol.swift`, `AgentStatus.swift`, `ClipboardServicing.swift`, `SpiceClipboardService.swift`, `VsockClipboardService.swift`, `VsockControlService.swift`, `VsockListenerHost.swift`, `VsockGuestLogService.swift`, `VsockPorts.swift`, `KernovaGuestAgentInfo.swift`

**Protocols:** `VirtualizationProviding`, `VMStorageProviding`, `DiskImageProviding`, `MacOSInstallProviding`, `IPSWProviding`, `USBDeviceProviding`

Services are split by concurrency requirements:

- **`@MainActor` services** (interact with `VZVirtualMachine`):
  - `VirtualizationService` — start, stop, pause, resume, save state, restore state. `start(_:)` has two branches: restore from a save file, or cold-boot (build a fresh `VZVirtualMachineConfiguration` and attach a new VM). The post-install auto-boot path also runs through cold-boot — see `MacOSInstallService` below for the synchronisation that makes that safe.
  - `MacOSInstallService` — loads restore image, creates platform files (aux storage, hardware model, machine identifier), runs `VZMacOSInstaller` with KVO progress tracking. After `installer.install()` resolves, it explicitly **waits for `vm.state` to reach `.stopped`** before returning. VZ's `install` completion handler fires while the post-install guest shutdown is still propagating through the framework's state machine — without the wait, the caller's auto-boot would cold-rebuild a `VZMacAuxiliaryStorage(contentsOf:)` while the install-side instance still held the file lock, producing the "Failed to lock auxiliary storage" error. Waiting also gives our `VZVirtualMachineDelegate.guestDidStop` a chance to fire, which releases our refs via `resetToStopped`; if the delegate doesn't fire within the timeout the install service tears down explicitly as belt-and-braces.
  - `USBDeviceService` — runtime attach/detach of USB mass-storage devices against the live VM's XHCI controller, behind `USBDeviceProviding` for mocking; used by the removable-media reconcile and the Guest Agent installer mount.

- **`Sendable` struct services** (no mutable state, safe to call from anywhere):
  - `VMStorageService` — creates/deletes/lists VM bundle directories at `~/Library/Application Support/Kernova/VMs/` and handles cloning (deep copy with new UUID)
  - `DiskImageService` — creates ASIF disk images by decompressing bundled lzfse-compressed templates (sandbox-safe, no subprocess)
  - `IPSWService` (`final class` for `URLSession` lifecycle) — fetches available macOS restore images from Apple's catalog and downloads IPSW files directly into a Finder-visible `.kernovadownload` bundle (`Info.plist` + `data` at the bundle root). Streams response chunks via a `URLSessionDataDelegate` bridged to an `AsyncThrowingStream<Data, Error>` (the per-byte overhead of `URLSession.bytes(for:)` is unacceptable at multi-GB scale); manual HTTP `Range` / `If-Range` against the IPSW CDN drives resume, with the data file's on-disk size as the resume offset. On completion the `data` file is moved to the user-chosen `.ipsw` destination and the bundle is trashed. Cancellation safety: `streamBytes` re-checks `Task.checkCancellation()` **after** the for-await loop, because `AsyncThrowingStream.next()` resolves to `nil` (not throw) when the consumer's task is cancelled while parked — without that post-loop check, a user-cancelled download would proceed past the loop and finalize partial bytes onto the destination. A companion byte-count check (`totalWritten == expectedTotal`) catches the rarer "server closed cleanly under Content-Length" case. On any throw from this region the bundle is preserved so the next Start can resume from the partial bytes. Stale bundles are auto-discarded when the stored `originalURL` differs from the caller's request or when `Info.plist` fails to decode. The `.kernovadownload` UTI conforms to `com.apple.package` so Finder shows the bundle as a single icon

- **`SystemSleepWatcher`** — `@MainActor` observer class that monitors `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`. Follows the same pattern as `VMDirectoryWatcher`: callback-driven, `nonisolated(unsafe)` for observer tokens, `start()`/`deinit` lifecycle. Owned by `VMLibraryViewModel`, which uses it to auto-pause running VMs before sleep and resume them on wake.

- **`AttachmentFileMonitor`** — `@MainActor` `@Observable` reactive existence tracker for external attachments: one `DispatchSource` per watched parent directory plus `NSWorkspace` mount notifications, surfacing an observable `existsByPath` map that drives the missing-file affordances in the settings list, Boot Order sheet, and delete sheet.

- **`SerialSocketRelay`** — `@unchecked Sendable` (NSLock + `DispatchSourceRead`) host-side AF_UNIX listener that exposes the guest serial port to an external terminal: best-effort tee of guest output, sole host-side writer of serial input; re-startable for hot-toggle. See the [serial console data flow](#serial-console-data-flow) under Views.

- **`ConfigurationBuilder`** — Translates a `VMConfiguration` into a `VZVirtualMachineConfiguration`. Handles three boot paths: `VZMacOSBootLoader` (macOS), `VZEFIBootLoader` (EFI/UEFI), and `VZLinuxBootLoader` (direct kernel boot). Configures CPU, memory, storage, network, display, keyboard, trackpad, and audio devices. When `clipboardSharingEnabled` is set on a Linux guest, configures a `VZVirtioConsoleDeviceConfiguration` with a SPICE-named port using raw `VZFileHandleSerialPortAttachment` pipes (not `VZSpiceAgentPortAttachment`); macOS guests instead carry clipboard over the vsock device. For macOS guests it always appends a `VZVirtioSocketDeviceConfiguration` so the host can install vsock listeners (log + clipboard) against the live device once the VM is created. Resolves symlinks on user-supplied paths (shared directories, kernel/initrd, ISO images) and validates them before passing to VZ — via the shared `PathValidation` helpers. File paths (kernel, initrd, ISO) are checked for existence and rejected if they point to directories. Shared directory validation checks existence, is-directory, readability, and writability (for read-write shares) against the resolved path.

- **`SpiceAgentProtocol`** — Pure data types and parsing for the SPICE agent wire format. Defines VDI chunk headers, VDAgent message headers, clipboard message types, and capability bitmasks. Includes `SpiceMessageBuilder` (builds wire-ready messages with a `port` parameter defaulting to `serverPort` for host-side use) and `SpiceAgentParser` (incremental parser handling fragmented data across multiple pipe reads). Fully `Sendable`, no I/O. Used only by the host-side `SpiceClipboardService` (Linux clipboard transport) — macOS guests use vsock instead, so the file is no longer multi-target.

- **`AgentStatus`** — Enum (`.waiting | .current(version) | .outdated(installed, bundled) | .unresponsive(version) | .expectedMissing(expected)`) that drives install/update/unresponsive/reinstall affordances in the sidebar and clipboard window. Sourced from `VsockControlService` for macOS guests (independent of clipboard sharing — first four cases) and from `SpiceClipboardService` for Linux guests (`.waiting` / `.current` only). The UI reads it via `VMInstance.agentStatus`, which dispatches by `configuration.guestOS` and synthesizes `.expectedMissing(expected:)` from the post-start watchdog flag plus `configuration.lastSeenAgentVersion` — `VsockControlService` itself does not (and cannot) produce that case because it has no access to persisted host state.

- **`ClipboardServicing`** — `@MainActor` protocol covering the public surface (`clipboardText`, `isConnected`, `start()`, `stop()`, `grabIfChanged()`) shared by both clipboard implementations. `VMInstance.clipboardService` holds the existential, so the clipboard window controllers don't branch on transport. Agent install/version state is *not* part of this protocol — for macOS guests it lives on `VsockControlService` (the always-on control channel, independent of whether clipboard sharing is enabled). `SpiceClipboardService` exposes its own `agentStatus` directly for Linux.

- **`KernovaGuestAgentInfo`** — Static accessors for the bundled guest agent. The "Package Guest Agent DMG" build phase extracts `CFBundleShortVersionString` from the built `KernovaGuestAgent` binary's embedded `__info_plist` section (via `otool -X -P | plutil -extract`) and writes it to `Resources/KernovaGuestAgentVersion.txt`; this file is the single source of truth for "what version did I bundle" and cannot drift from the actual agent binary. The accessor reads the sidecar lazily; missing/empty files trip an `assertionFailure` since the build phase is required to produce them. Also exposes the installer DMG URL.

- **`SpiceClipboardService`** — `@MainActor` `ClipboardServicing` implementation for Linux guests. Reads from the guest pipe on a background GCD queue, parses messages via `SpiceAgentParser`, and exposes `clipboardText` (observable, editable by the UI) and `isConnected`. When the clipboard window loses focus, `grabIfChanged()` sends a `CLIPBOARD_GRAB` if the text was edited. Uses raw pipes rather than `VZSpiceAgentPortAttachment` so clipboard data flows through the gated UI instead of the host `NSPasteboard`.

- **`VsockClipboardService`** — `@MainActor` `ClipboardServicing` implementation for macOS guests, layered on `VsockChannel`. Outbound clipboard changes are announced as `ClipboardOffer` with a monotonically increasing `generation`, then the guest pulls the bytes via `ClipboardRequest` / `ClipboardData`. Inbound flow is symmetrical (offer → request → data). Stale generations are detected by both sides so a `ClipboardData` reply that races a newer offer is dropped rather than overwriting fresher state. The service is constructed lazily by the vsock clipboard listener when the guest connects, so `VMInstance.clipboardService` may be nil until then. No `Hello` is exchanged on this channel — version/liveness moved to `VsockControlService`.

- **`VsockControlService`** — `@MainActor` `@Observable` consumer of the always-on control channel (`KernovaVsockPort.control = 49154`). Sends a host `Hello` on start; processes the guest's `Hello` to populate `agentVersion` and `isConnected`; emits and consumes bidirectional `Heartbeat` frames on a configurable cadence (default 5 s). A liveness watchdog flips `agentStatus` to `.unresponsive(version:)` after `unresponsiveAfter` (default 15 s) of inbound silence, and tears down the channel after `terminateAfter` (default 30 s) — letting the listener accept a fresh connection. `agentStatus` compares the guest-reported `Hello.agent_info.agent_version` against `KernovaGuestAgentInfo.bundledVersion` using `String.compare(_:options: .numeric)` (correct for dotted-decimal SemVer like `0.9.0` vs `0.10.0`); a `bundledAgentVersion` initializer parameter lets tests vary the comparison target. The listener is installed unconditionally for every macOS guest with a `VZVirtioSocketDevice`, so `agentStatus` is meaningful even when clipboard sharing is disabled. Also delivers the per-VM toggle policy to the guest: an optional `policyProvider: () -> AgentPolicySnapshot` closure is read on every guest `Hello` and the resulting snapshot is sent as a `PolicyUpdate` frame so the guest agent knows which capabilities (log forwarding, clipboard sharing) to enable. `sendPolicyUpdate(_:)` is also public so runtime hot-toggle pushes can reuse the same path. An optional `onAgentVersionObserved: (String) -> Void` closure fires once per guest `Hello` carrying a non-empty `agent_version`; `VMInstance.startVsockServices` wires it to `recordObservedAgentVersion(_:)`, which persists the new value via `onUpdateConfiguration` (routed through the view-model's `updateConfiguration` dispatcher) and clears the post-start watchdog state.

- **`AgentPolicySnapshot`** — Plain `Equatable` `Sendable` struct (`logForwardingEnabled`, `clipboardSharingEnabled`) carrying the pair of toggles the guest agent honors. Decouples `VsockControlService` from `VMConfiguration`: the host injects a closure that reads the latest config when policy is sent, so reconnects always pick up the current snapshot.

- **`VsockListenerHost`** — `@MainActor` wrapper around `VZVirtioSocketListener` bound to one vsock port. The nonisolated `VZVirtioSocketListenerDelegate` callback dups the connection's file descriptor and bridges back to MainActor before constructing a `VsockChannel` and handing it to a caller-supplied closure. One instance per service; multiple coexist on the same `VZVirtioSocketDevice`.

- **`VsockGuestLogService`** — `@MainActor` consumer that owns one accepted `VsockChannel` for the lifetime of a guest connection. Forwards `LogRecord` frames through a `GuestLogEmitter` abstraction (default `OSLogGuestLogEmitter`, subsystem `com.kernova.guest`); guest log levels map 1:1 onto `os.Logger` methods. `Error` frames go to the host's own diagnostic logger; `Hello` / `Heartbeat` payloads on this port log a wrong-port warning (those belong on the control channel). The service self-terminates on EOF.

- **`VsockPorts`** — Central registry of port assignments (`KernovaVsockPort.control = 49154`, `KernovaVsockPort.clipboard = 49152`, `KernovaVsockPort.log = 49153`) so each service gets its own listener on a distinct port instead of in-band multiplexing. The control listener is always installed for macOS guests with a `VZVirtioSocketDevice`; the log listener is gated on `configuration.agentLogForwardingEnabled`; the clipboard listener is gated on `configuration.clipboardSharingEnabled`. Both gates are also re-evaluated at runtime via `VMInstance.applyLivePolicy(oldConfig:newConfig:)` — flipping the toggle while a macOS VM is running installs or tears down the listener and pushes a fresh `PolicyUpdate` to the guest agent. Linux clipboard sharing is restart-only (the SPICE port must be declared at config-build time).

#### Storage topology mirrors VZ

`VMConfiguration` carries two ordered lists that map directly onto VZ's two storage surfaces. `storageDisks: [StorageDisk]?` maps onto `vzConfig.storageDevices`; position [0] boots first on EFI guests. Each entry's `kind` (`.virtio` or `.usbMassStorage`) is inferred from the file extension at add-time via `StorageDisk.defaultKind(forPath:)` — `.iso`/`.dmg` default to USB mass storage so installer media doesn't shift the main disk's `/dev/vda` letter when reordered for boot, everything else defaults to virtio. `removableMedia: [RemovableMediaItem]?` maps onto `usbControllers[0].usbDevices` — hot-pluggable, no boot semantics. The same bundled-disk entry (`Disk.asif`, internal, virtio) appears in `storageDisks` as a regular row; nothing in the data model singles it out as "the main disk." Each `StorageDisk` carries a user-editable `label` (renamed inline or via the row context menu through `VMLibraryViewModel.renameStorageDisk`; cosmetic — the backing file keeps its stable UUID name and the guest is unaffected); new disks get a collision-free default label via `StorageDisk.uniqueLabel`. The model stores **no** physical sizing — on-disk footprint, virtual capacity, and creation date are read live from the file at display time (uniformly for the main disk and additional disks), since a size can change out-of-band (e.g. a CLI resize) and any stored copy would go stale. The subtitle reads run **off the main thread** via `populateDiskSubtitle` (placeholder → detached read → fill-in; reads are cancelled when a field is re-bound); Get Info also reads off-main (a detached size + creation-date read, then presents). Both attachment lists share one `VMSettingsViewController` implementation — `refreshAttachmentList`/`makeAttachmentRow` (rebuild vs. in-place), one `buildAttachmentContextMenu` with eight `@objc` handlers dispatched on an `AttachmentRef(kind, id)` `representedObject` (Eject is removable-only, so its handler is a no-op for storage refs), `presentAttachmentInfoPopover`, and `commitAttachmentRename` — parameterized by `AttachmentKind` rather than duplicated per list. **Removable media (`RemovableMediaItem`) is at full parity with storage disks**: same editable `label` (inline rename or context menu, via `VMLibraryViewModel.renameRemovableMedia` — safe to rename while running, since a label-only edit leaves `path`/`readOnly` untouched and the reconcile only detaches/reattaches on those, so the medium stays mounted), the same `AttachmentRowView` UI **plus an inline trailing Eject button that storage rows omit** (a one-click detach — no confirmation, file untouched, via `removeRemovableMedia(_:from:trashFile: false)` — hot-pluggable media is swapped often, so it earns a dedicated control; the eject glyph is shared with the Shared Directories row button), the right-click menu (Rename / Get Info / Show in Finder / Copy Path / Copy File Name / Read Only / **Eject** / Remove — Eject, the no-confirmation detach, is removable-only, the one menu item storage rows lack), the same `AttachmentInfoPopoverContentViewController`, and the same live on-disk/allocated sizing (always external — a raw `.iso`/`.dmg` reports its logical size as the capacity).

#### Live-editable fields and their dispatch

`VMConfiguration.liveEditableFieldsChanged(old:new:)` is the single source of truth for "did anything change that should take effect while the VM is running?" It combines `hotToggleFields` (a typed `[KeyPath<VMConfiguration, Bool>]`) with `removableMediaChanged(old:new:)`, which array-compares the `removableMedia` lists. `storageDisks` changes are deliberately NOT live-editable — they go to `vzConfig.storageDevices`, which VZ requires fixed at start time, so the settings UI keeps that section locked while the VM is running. `VMSettingsViewController` mutates via the centralized `VMLibraryViewModel.updateConfiguration(of:mutate:)` dispatcher (persist + `applyLivePolicy`). Every control's target/action handler routes its write through this dispatcher; no settings control writes to `instance.configuration` directly.

#### Removable-media reconcile

`VMLibraryViewModel.applyLivePolicy(for:old:new:)` forks: vsock listener changes go through `VMInstance.applyLivePolicy`; `removableMedia` changes are dropped into `pendingRemovableMediaTarget` and a coalesce-and-drain task (`runRemovableMediaReconciliation`) calls `applyLiveRemovableMediaChange(for:target:)` until the pending dictionary empties. The reconciler computes a per-id diff against `instance.liveRemovableMedia` (add / remove / mutate-in-place / reorder-noop), detaches first to avoid duplicate-UUID conflicts on swaps, then attaches. `deviceNotFound` (guest-side ejection) and `noVirtualMachine` (VM torn down) are handled distinctly; on any other framework error the reconciler calls `reconcileConfigToLiveState(for:lookup:)` to rebuild `config.removableMedia` from `instance.liveRemovableMedia` — so the UI snaps to what's actually attached instead of describing a state VZ refused. The rollback bypasses `updateConfiguration` (direct write + `saveConfiguration`) to avoid re-entering the reconcile pipeline.

#### Save-state device UUID persistence

`VZUSBDeviceConfiguration.uuid` is matched against the saved-state file's recorded device list during `restoreMachineStateFrom(url:)` — fresh UUIDs each launch would break restore. `RemovableMediaItem.id` becomes `VZUSBMassStorageDeviceConfiguration.uuid` and is persisted with the entry in `config.json`. For virtio entries in `storageDisks`, the entry's `id` is also used as the `VZVirtioBlockDeviceConfiguration.blockDeviceIdentifier` (truncated to 20 ASCII chars), giving Linux guests a stable `/dev/disk/by-id/virtio-<identifier>` symlink — with the exception of the bundle's primary disk (`Disk.asif`, identified by `ConfigurationBuilder.isMainBundleDisk(_:layout:)`), which intentionally has no `blockDeviceIdentifier` set so the pre-refactor `/etc/fstab` behavior is preserved. The synthesized default main disk (used when `storageDisks` is nil/empty) derives its UUID deterministically from `SHA256(bundleURL.path)` via `ConfigurationBuilder.stableMainDiskID(forBundleAt:)`, so entry-by-id lookups (notably `removeStorageDisk` and the settings list's read-only/delete row actions) are stable before the user has materialized the list. `clonedForNewInstance` regenerates every `StorageDisk.id` and `RemovableMediaItem.id` so two bundles don't share device identity.

All service implementations conform to protocols defined in `Services/Protocols/`. This enables full dependency injection — tests use mock implementations that track call counts and support error injection.

### ViewModels

**Files:** `VMLibraryViewModel.swift`, `VMLibraryPresenting.swift`, `VMLifecycleCoordinator.swift`, `VMCreationViewModel.swift`, `VMDirectoryWatcher.swift`

- **`VMLibraryViewModel`** is the central `@Observable` view model. It owns the array of `VMInstance`s and handles list-level operations: add, remove, rename, reorder, selection tracking. VM order is user-customizable via drag-and-drop in the sidebar, persisted as a UUID array in `UserDefaults` (key `"vmOrder"`). VMs not in the custom order (newly created/discovered) sort after ordered VMs by `createdAt`. For lifecycle operations (start, stop, install), it delegates to `VMLifecycleCoordinator`. Clone and import operations use a "phantom row" pattern: a `VMInstance` with `isPreparing = true` appears immediately in the sidebar with a spinner while the file copy runs asynchronously via `Task.detached`. The `hasPreparing` computed property enforces serialization — only one clone/import at a time. Cancellation removes the phantom row, cancels the task, and cleans up partial files on disk. Force-stop is surfaced via `confirmForceStop()` which presents a confirmation dialog. **All `VMConfiguration` mutations route through `updateConfiguration(of:mutate:)`** — a single dispatcher that takes an `inout` closure, no-ops when the closure produces an equal value, persists via `saveConfiguration`, and calls `applyLivePolicy(for:old:new:)`. This is the only place persist + live-policy fire together; settings-UI bindings (`configBinding`, `storageDiskBinding`, `removableMediaBinding`), install/uninstall flows, rename, display-window callbacks, and guest-driven `VMInstance.onUpdateConfiguration` writes all funnel through it. It surfaces alerts, sheets, and the wizard imperatively via the `VMLibraryPresenting` delegate (implemented by `DetailContainerViewController`).

- **`VMLifecycleCoordinator`** is an `@MainActor` coordinator that owns the lifecycle services (`VirtualizationService`, `MacOSInstallService`, `IPSWService`). It orchestrates multi-step operations like macOS installation (which involves IPSW download → platform file creation → VM configuration → installation). This separation keeps `VMLibraryViewModel` focused on list management. The coordinator enforces **per-VM operation serialization** — at most one lifecycle operation can be in flight for a given VM at any time; concurrent requests are rejected with `VMLifecycleCoordinator.LifecycleError.operationInProgress`. `stop` and `forceStop` bypass serialization entirely (clearing the active-operation token before calling the service) so users can always cancel hung operations.

- **`VMCreationViewModel`** drives the multi-step creation wizard. It tracks the current step, validates inputs at each stage, and produces a `VMConfiguration` + disk image on completion. It is a pure `@Observable` state machine with no UI framework dependency — the wizard's pure-AppKit step view controllers (`Views/Creation/`) read/write it directly and the shell observes it via `observeRecurring`.

- **`VMDirectoryWatcher`** uses `DispatchSource.makeFileSystemObjectSource` to monitor the VMs directory for external changes (e.g., a user restoring a VM from Trash via Finder). When changes are detected, it triggers reconciliation in `VMLibraryViewModel` to sync the in-memory list with disk.

- **`SystemSleepWatcher`** (see Services section) is also owned by `VMLibraryViewModel`, triggering `pauseAllForSleep()` and `resumeAllAfterWake()` on system sleep/wake events. Auto-paused VMs are tracked in `sleepPausedInstanceIDs` so user-paused VMs are not accidentally resumed.

### Views

The entire app target is pure AppKit — `NSViewController`/`NSView` subclasses plus free `make*` atom-factory functions, with no `import SwiftUI` anywhere. Views observe `VMLibraryViewModel` and individual `VMInstance`s via the Observation framework (`observeRecurring`).

#### Sidebar

`SidebarViewController` is a source-list `NSOutlineView`: VMs under a collapsible "Virtual Machines" group (`SidebarSection` is structured so a second group would be a localized addition), selection synced with `selectedID`, double-click-to-start, a status-dependent context menu, inline rename, and drag-reorder plus Finder-bundle import. `SidebarVMRowCellView` renders each VM row: a state-tinted OS icon (swapped in place for a spinner while busy), the VM name, and an optional agent accessory; it owns a per-instance `ObservationLoop` for live updates and hosts the inline-rename field editor. `SidebarAgentStatusButtonView` is the agent accessory — a stacked `NSButton` (SF Symbol for static states) and `.mini` spinning `NSProgressIndicator` (for `.connecting`); it owns a `PopoverPresenter` + `AgentStatusPopoverContentViewController`, refreshes the popover in place when status changes mid-popover (e.g. `.waiting` → `.current`), and anchors `.maxX` so the popover flows into the detail-pane area rather than out the sidebar's right edge. The popover content shows a per-status title, wrapping body, and an action row — an optional "Don't show again" link (surfaced only for `.waiting`) plus a per-status action button ("Install Guest Agent…" / "Update Guest Agent…" / "Reinstall Guest Agent…" / "Done") — through a delegate protocol (`didTapAction` + `didTapDismiss`); static helpers expose `title(for:)`, `bodyText(for:vmName:)`, `actionButtonTitle(for:)`, and `requiresMountAction(for:)`, and `update(status:vmName:hasDismissAction:)` swaps labels in place.

#### Detail routing

`VMDetailRouterViewController` resolves a `DetailRoute` from instance status — via the pure, unit-tested `DetailRoute.resolve(preparingLabel:status:hasInstallState:detailPaneMode:)` — and swaps its reused children: `VMSettingsViewController`, `DetailStatusPlaceholderViewController` (centered spinner + label for transient states and clone/import preparing), `MacOSInstallProgressViewController`, or the display placeholder. For the initial-boot route it stacks `InitialBootBannerView` (orange banner with an install-context-aware subtitle) above the settings form. It rebuilds per-instance state on VM switch via `reconfigure(instance:)`. `MacOSInstallProgressViewController` renders the two-step (download → install) progress — numbered step circles + connector, linear progress bar, monospaced detail text — observing `instance.installState`; Cancel confirms via `presentSheetAlert`. `DetailEmptyStateView` is the centered "No Virtual Machine Selected" state with a New Virtual Machine button (calls the container's `presentCreationWizard()`).

#### Settings

`VMSettingsViewController` is the VM configuration editor: nine grouped-form sections built with the `GroupedFormStyle` factories, observation-driven idempotent `apply()`, and lockable sections disabled while the VM runs (their headers/info stay live). All writes route through `VMLibraryViewModel.updateConfiguration`. Per-row storage/removable delete shows a context-aware confirmation decided by the pure `attachmentDeletePrompt(...)` helper, matching the VM-delete sheet's rules (internal disk → Move-to-Trash-or-Cancel; private external → trash or detach; shared external → detach-only naming the other VMs; Guest Agent installer → detach-only, file never trashed). The form rebuilds on VM switch. `MicPermissionPresentation` holds the pure, unit-tested helpers behind the mic-permission warning bar (`micPermissionPresentation(_:micEnabled:)`, `externalAttachmentPaths(for:)`, `isGuestAgentSectionVisible(guestOS:)`).

#### Attachment rows and live sizing

`AttachmentRowView` renders one attachment row — a storage disk **or** a removable medium: leading icon + title + subtitle + Read Only switch + an optional trailing inline Eject button (removable-media rows only — a one-click detach with no confirmation, file untouched, since hot-pluggable media is swapped often; storage-disk rows pass `ejectButton: nil` and detach via the right-click menu; the file-trashing Remove, with confirmation, always lives in the right-click menu on every row). Rows support inline title rename (double-click; mirrors `SidebarVMRowCellView`'s field-editor state machine and commits on any click outside the field via a local mouse-down monitor), a per-row right-click menu via `menu(for:)` → controller-supplied closure, and `update(...)` to patch title/icon/Read-Only/enabled state **in place** — so a non-structural refresh (e.g. a rename) doesn't tear the row down and re-fade its size. Each row carries `itemID` + `infoAnchor` (the icon, so Get Info points at it) + `subtitleField` (so the controller re-populates the live size off-main). `AttachmentIconButton` is the leading-icon control: SF Symbol when the file is present, red-triangle button + missing-file popover (`MissingAttachmentPopoverContentViewController`, via `PopoverPresenter`) when it's gone; an optional `onActivate` makes the present-state icon clickable (storage rows wire it to Get Info), inert by default.

The subtitle pipeline lives in `StorageDiskSubtitle.swift`: `nonisolated diskSubtitle(for:bundleLayout:)` reads `diskOnDiskBytes` + `diskCapacityBytes` **live** (no main-thread file I/O — it runs on a detached task), and `@MainActor populateDiskSubtitle(…:isMissing:animated:)` (with `StorageDisk` / `RemovableMediaItem` convenience overloads) fills the label in: the field's `identifier` is tagged with the disk id so a recycled Boot Order cell ignores a stale result and a same-disk refresh updates in place; a re-bind cancels the prior in-flight read via a generation-tagged map; `animated: false` skips the fade so the Boot Order sheet's drag-drop `reloadData()` doesn't flicker. The "In-bundle disk image" placeholder is **deferred** behind a ~100 ms grace and cancelled when the read lands, so the sub-ms common case never flickers it — only a genuinely slow read surfaces it. Every disk — in-bundle or external, ASIF or raw `.img`/`.iso`/`.dmg` — shows `<on disk> / <allocated>` uniformly (the main disk included), reflecting current state (e.g. an external resize); it falls back to on-disk-only when capacity isn't readable, then to the file's path when neither figure reads. An external disk seeds its path as the holding value while the read runs (so it never flickers and needs no placeholder); a **missing** external file short-circuits to the red "Missing —" state (`AttachmentSubtitleLabel`'s bold `systemRed` prefix). `diskIconSystemName(for:)` supplies the per-kind icon. Used by both the settings list and the Boot Order sheet.

#### Popovers, sheets, and alerts

Every popover, sheet, and alert is end-to-end AppKit — a real `NSPopover`/`NSAlert`/sheet, with controllers building their full layouts in `loadView()` from shared token sets (`CalloutStyle` for callout popovers, `GroupedFormStyle` for grouped forms shared with the wizard) plus atom factory functions. **All popover anchors target a wrapper `NSView`** (never an inner control) so `NSPopover.preferredEdge` semantics are interpreted in an unflipped coordinate system. **No shared callout/form container or base class** — visual consistency comes from shared tokens, not inheritance. **Genuinely shareable controllers are reused via init parameterization**: `DiskSizePopoverContentViewController` (headline + size `NSPopUpButton` + caption + Cancel/Create) serves both the Storage Disk and Removable Media Create flows via injected `headline`/`caption`; its `DiskSizePopoverCoordinator` owns the `PopoverPresenter` and forwards the confirmed size to an `onConfirm` closure (the settings VC wires in-bundle disk creation vs. the removable-media save panel). `InfoPopoverContentViewController` backs the generic `info.circle` surface (`InfoButtonView`), taking `[InfoPopoverParagraph]` where each paragraph is `.body(String)` or `.code(String)` — `.code` uses `makeCalloutCode` for monospaced selectable snippets (e.g. the virtiofs `mount` command). `MicrophonePermissionPopoverContentViewController` keeps its unique structure (divider + sub-headline + numbered steps with bold runs + tail caption) in its own concrete subclass rather than bloating `InfoPopoverParagraph`. `AttachmentInfoPopoverContentViewController` is the attachment Get Info popover — headline + two-column `NSGridView` of facts (file, on-disk, allocated, read-only, bus, created) + monospaced selectable full path — initialized from a value snapshot (no live `VMInstance`).

AppKit content controllers decouple from `VMLibraryViewModel` via delegate protocols; their hosts (settings VC, alerts presenter) implement the delegates and forward user choices to the view model. Conversely, the view model surfaces alerts, sheets, and the wizard by calling its `VMLibraryPresenting` delegate (`DetailContainerViewController`) imperatively — not by toggling observed `show*` flags. Errors raised before the delegate attaches (e.g. the initial `loadVMs()` in `init`) are buffered on the view model and flushed when it is set.

Two sheets are rich enough for `SheetPresenter` rather than `NSAlert`:

- **Delete-VM sheet** (`DeleteVMSheetContentViewController`) — red trash icon header + body paragraph + scrollable two-section list + Cancel / Move-to-Trash buttons. Section 1 "Removed with the VM" lists the VM's in-bundle disks read-only; section 2 "Files outside this VM" lists external disks/media with a per-row checkbox (exclusively-owned default to on; shared *or* missing-file rows are locked off and never collected on confirm — shared show a "Kept — still used by …" note, missing show the red "Missing —" path style plus an "Already gone — nothing to remove" note; when both, the shared note wins). Per-file `isMissing` is resolved off-main by `VMLibraryViewModel.externalAttachmentsResolvingExistence(for:)` before the presenter assembles the sheet (the synchronous `externalAttachments(for:)` leaves it `false`, keeping the trash fan-out free of main-thread filesystem syscalls). The delegate fires `didCancel` / `didConfirmTrashingExternalIDs(Set<UUID>)`. Presented by `DetailAlertsPresenter` for every delete. Move-to-Trash is intentionally the default action (Return) AND destructive (red tint).
- **Boot Order sheet** (`StorageDiskReorderSheetContentViewController`) — headline + `InfoButtonView` header, a view-based `NSTableView` (alternating rows, hidden headers) inside an `NSScrollView`, Done button. Drag-anywhere reorder via the native `NSTableView` drag-and-drop machinery (`pasteboardWriterForRow:`, `validateDrop:`, `acceptDrop:`); the pure index-math primitive is exposed as `performReorder(sourceRow:proposedRow:)` so tests exercise it without mocking `NSDraggingInfo`. It re-arms a `withObservationTracking` subscription on `fileMonitor.existsByPath` so missing-file affordances update live without dismiss/re-present. Presented by the settings VC via `SheetPresenter`.

#### Display

`VMDisplayBackingView` is the pure-AppKit VM display — it hosts `VZVirtualMachineView` with pause/transition overlays. In the detail pane, `DetailContainerViewController` layers it on top of the detail content; in pop-out/fullscreen windows, `VMDisplayWindowController` uses it directly as the window's content view. `VMDisplayPlaceholderContentViewController` is the detail-pane placeholder when the display is unavailable inline — a centered empty state (SF Symbol + title + description + optional action button) for the non-inline states (Fullscreen / Popped Out / Suspended / No Display), with an inert black fill behind it for the `.live` case (covered by `VMDisplayBackingView`). It observes `VMInstance.displayMode`, `isColdPaused`, and `virtualMachine` via `observeRecurring`; action buttons dispatch through `NSApp.sendAction(_:to:from:)` to `AppDelegate.toggleFullscreen(_:)` / `togglePopOut(_:)`. The reusable `DisplayPlaceholderEmptyStateView` lives privately in the same file (one consumer today; no premature extraction).

#### Creation wizard

`VMCreationWizardViewController` is the shell — step indicator (`WizardStepIndicatorView`) + swappable child step VCs + nav bar — observing `VMCreationViewModel` and reporting Cancel/Create via `VMCreationWizardViewControllerDelegate`. The steps are concrete `NSViewController`s: `OSSelectionContentViewController` (step 1), `IPSWSelectionContentViewController` / `BootConfigContentViewController` (step 2, chosen by OS), `ResourceConfigContentViewController` (step 3, `NSGridView` form), and `ReviewContentViewController` (step 4). `WizardStyle` provides the scoped design tokens + `make*` atom factories (title/subtitle/form rows, section headers, banner, path badge, scroll-view helper); the wizard shares the grouped-form atoms in `GroupedFormStyle` with the settings pane.

#### View hierarchy

```
NSSplitViewController (MainWindowController)
├── Sidebar pane: SidebarViewController → NSOutlineView (source list) → SidebarVMRowCellView (per VM)
└── Detail pane: DetailContainerViewController  (owns DetailAlertsPresenter for lifecycle confirmation alerts)
    ├── VMDisplayBackingView (AppKit, layered on top — shown when VM running inline)
    │   └── VZVirtualMachineView + pause/transition overlays
    └── Detail content (AppKit, behind): DetailEmptyStateView  ⇆  VMDetailRouterViewController
            ├── VMSettingsViewController                       (route: stopped/error/initialBoot/running-settings)
            ├── InitialBootBannerView + VMSettingsViewController (route: initialBoot)
            ├── DetailStatusPlaceholderViewController          (route: preparing / transition)
            ├── MacOSInstallProgressViewController             (route: installing)
            └── VMDisplayPlaceholderContentViewController      (route: display — placeholder when external/suspended/unavailable)
VMCreationWizardViewController (pure-AppKit modal sheet; presented by DetailContainerViewController via SheetPresenter when presentCreationWizard() is called)
├── OSSelectionContentViewController
├── IPSWSelectionContentViewController / BootConfigContentViewController   (chosen by selectedOS on entry)
├── ResourceConfigContentViewController
└── ReviewContentViewController
```

#### Serial console data flow

The guest serial output pipe has a single reader — `VMInstance.startSerialReading`'s `readabilityHandler` (background GCD queue) — which fans out to (a) `serial.log` (authoritative, always on) and (b) `SerialSocketRelay.forwardOutput` (best-effort tee, only when `serialSocketRelayEnabled`). An external terminal attaches to the relay's AF_UNIX socket; bytes it sends are written straight to the serial input pipe, making the relay the sole host-side writer of serial input. There is no in-app terminal emulator and no serial window — emulation is delegated to the user's terminal. The connect instructions and the (per-VM deterministic) socket path are surfaced via the info button on the **Serial Console** section of `VMSettingsViewController` (the path is `VMInstance.serialSocketPath(for:)`, computed the same way the relay binds it). The relay socket lives under `NSTemporaryDirectory()` (short path; the bundle dir overflows `sockaddr_un.sun_path`) and is App-Sandbox/Mac-App-Store-compatible (no entitlement). The per-VM `serialSocketRelayEnabled` flag is hot-toggleable via `applyLivePolicy` → `applyLiveSerialRelayPolicy`, handled before the vsock-socket-device guard since the relay is host-only.

### Data Flow

```
AppDelegate
    │
    ├── creates → VMLibraryViewModel (owns [VMInstance])
    ├── creates → VMLifecycleCoordinator (owns services)
    │                 ├── VirtualizationService
    │                 ├── MacOSInstallService
    │                 ├── IPSWService
    │                 ├── VMStorageService
    │                 └── DiskImageService
    │
    ├── creates → MainWindowController (NSSplitViewController + NSToolbar)
    │                 ├── Sidebar: SidebarViewController (NSOutlineView source list)
    │                 └── Detail:  DetailContainerViewController
    │                              ├── VMDisplayBackingView (AppKit VM display, layered on top)
    │                              └── DetailEmptyStateView ⇆ VMDetailRouterViewController (AppKit)
    │
    ├── manages → VMDisplayWindowController (per VM)
    └── manages → ClipboardWindowController (per VM)

AppKit views ──observe──→ VMLibraryViewModel ──delegates──→ VMLifecycleCoordinator ──calls──→ Services
                           VMInstance (per VM)

SystemSleepWatcher ──sleep/wake──→ VMLibraryViewModel ──pause/resume──→ VMLifecycleCoordinator
```

### Utilities

**Files:** `DataFormatters.swift`, `UniqueName.swift`, `PathValidation.swift`, `InlineRenameSizing.swift`, `NSImageExtensions.swift`, `NSViewExtensions.swift`, `NSOpenPanelExtensions.swift`, `DesignTokens.swift`, `ObservationLoop.swift`, `PopoverPresenter.swift`, `SheetPresenter.swift`, `SheetAlert.swift`, `DetailAlertsPresenter.swift`

- `DataFormatters` — human-readable formatting for bytes (e.g., "107.4 GB"), CPU counts, etc.
- `UniqueName` — `UniqueName.firstAvailable(prefix:existing:)`, the shared collision-free name generation backing both `StorageDisk.uniqueLabel` (bare numeric suffix) and `VMConfiguration.generateCloneName` (" Copy" infix)
- `PathValidation` — shared path-validation helpers (resolve symlinks, check existence/type/permissions), used by `ConfigurationBuilder` and `USBDeviceService`
- `InlineRenameSizing` — text-hugging sizing for the inline-rename field editors (sidebar rows, attachment rows)
- `NSImageExtensions` — `NSImage.systemSymbol(_:accessibilityDescription:)` for nil-safe SF Symbol loading with error logging
- `NSViewExtensions` — full-size subview constraint helper
- `NSOpenPanelExtensions` — pre-configured `NSOpenPanel` factory for browsing disk images
- `DesignTokens` — centralized `Spacing` scale, `StatusColor` palette, and shared `Typography` font token
- `ObservationLoop` — `observeRecurring(track:apply:) -> ObservationLoop` helper that encapsulates the `withObservationTracking` + `Task { @MainActor }` + recursive re-register dance. Returns a cancel token stored by the caller; the loop stops when the token is deallocated or `cancel()` is called. Used by every observation site (window controllers, detail/sidebar/wizard VCs, `AppDelegate.observeForTermination`) so each site only declares *what* to track and *what* to do — not how to sustain the loop
- `PopoverPresenter` — `NSPopover` lifecycle wrapper: one instance per anchor, refreshes content in place if shown again, fires `onClose` after dismissal
- `SheetPresenter` — custom-content sheet lifecycle wrapper: wraps an `NSViewController` in an `NSWindow` and attaches it as a sheet via `parent.beginSheet(_:completionHandler:)`. Use for richer sheets than `NSAlert` can express (the Delete-VM and Boot Order sheets)
- `SheetAlert` — AppKit `NSAlert` presenter: `AlertConfiguration` (title + message + ordered `[AlertButton]`) with a role enum (`.default` / `.cancel` / `.destructive` / `.standard`) mapping to key-equivalents and `hasDestructiveAction`; `presentSheetAlert(_:in:completion:)` shows the alert as a window-modal sheet
- `DetailAlertsPresenter` — imperative presenter for the detail-pane lifecycle alerts + delete sheet (delete sheet, cancel-preparing, force-stop, stop-paused, error, installer-mounted). `DetailContainerViewController` forwards `VMLibraryPresenting` calls here; it serializes presentations (one at a time, queueing the rest) and shows each via `presentSheetAlert` / `SheetPresenter(DeleteVMSheetContentViewController)`. Owned by `DetailContainerViewController` so alerts survive while the VM display is showing

## Key Design Decisions

### 1. Pure-AppKit UI

**What:** The app is entirely AppKit. `NSSplitViewController` owns the sidebar/detail layout, `NSToolbar` with native `NSToolbarItem`s the toolbar, and `NSWindow` window management. The sidebar is a source-list `NSOutlineView` (`SidebarViewController`); the detail pane is an empty-state view ⇆ `VMDetailRouterViewController` (`VMSettingsViewController` + placeholders + install progress). The VM display (`VZVirtualMachineView`) is managed by `VMDisplayBackingView` — in the detail pane `DetailContainerViewController` layers it on top of the detail content, and in pop-out/fullscreen windows `VMDisplayWindowController` uses it directly as the window's content view. The app target imports no SwiftUI.

**Why:** The app needs precise control over native macOS chrome — toolbar items, split-view behavior, sidebar collapsibility, popover/sheet anchoring — and Swift 6 strict-concurrency-friendly observation. SwiftUI's `NavigationSplitView`/`.toolbar` and the AppKit↔SwiftUI bridge boundaries proved fragile for this; the project incrementally converted every surface (sidebar, wizard, popovers/alerts, then the detail pane) to AppKit. Toolbar state is validated via `NSToolbarItemValidation`, observation is centralized in `observeRecurring`, and there are no hosting-bridge quirks.

**Alternatives:** SwiftUI `NavigationSplitView` with `.toolbar` modifiers — simpler but encountered persistent toolbar layout issues. A hybrid AppKit-shell / SwiftUI-content app (the prior architecture) — workable, but the bridge shims (sheet/popover anchors, `WindowAccessor`) added complexity that pure AppKit removed.

### 2. VM bundle as `.kernova` package directory

**What:** Each VM is a directory with a `.kernova` extension containing `config.json`, the disk image, auxiliary storage, save files, and serial logs.

**Why:** Treats each VM as an atomic unit in Finder. Users can move, copy, or delete VM bundles as single items. The directory structure is predictable via `VMBundleLayout`, and `config.json` makes the format human-inspectable.

**Alternatives:** SQLite database, single directory with UUID-named files, or Core Data. The bundle approach is simpler and more transparent.

### 3. ASIF disk images via bundled templates

**What:** Disk images use Apple Sparse Image Format (ASIF), a macOS 26 format. Pre-built templates are stored lzfse-compressed in `DiskTemplates/` (~3 KB each) and decompressed at VM creation time.

**Why:** ASIF provides near-native SSD performance with space efficiency — a 100 GB disk image starts at ~4 MB on disk and grows as the guest writes data. The template approach is fully sandbox-safe (no subprocess spawning), unlike the previous `hdiutil`-based approach.

**Alternatives:** Raw disk images (simple but waste space), QCOW2 (not natively supported by Virtualization.framework), or runtime `hdiutil` invocation (not sandbox-safe, requires process spawning).

### 4. `@MainActor` isolation strategy

**What:** Everything touching `VZVirtualMachine` is `@MainActor`-isolated. `VMInstance`, `VirtualizationService`, and `MacOSInstallService` are all `@MainActor`. Services that don't touch VZ are `Sendable` structs with no mutable state.

**Why:** `VZVirtualMachine` is main-thread-only (Apple requirement). Swift 6 strict concurrency enforces this at compile time. Making the boundary explicit prevents accidental cross-thread access. `Sendable` structs for stateless services avoid unnecessary main-thread bottlenecks.

**Bridging:** Some `VZVirtualMachine` delegate callbacks arrive on the main thread but aren't marked `@MainActor` in the API. These use `nonisolated(unsafe)` with `MainActor.assumeIsolated` to bridge back.

**Alternatives:** Wrapping all VZ access in `MainActor.run {}` calls — more boilerplate and easier to miss a call site.

### 5. Service protocol abstraction

**What:** Every service has a corresponding protocol (`VirtualizationProviding`, `VMStorageProviding`, etc.) defined in `Services/Protocols/`.

**Why:** Enables dependency injection for testing. Mock implementations can track call counts, return canned responses, and inject errors via `throwError` properties. The coordinator and view models accept protocol types, not concrete implementations.

**Alternatives:** No protocols, test against real services — would require actual VM operations in tests, making them slow and environment-dependent.

### 6. VMLifecycleCoordinator separation

**What:** `VMLifecycleCoordinator` sits between `VMLibraryViewModel` and the services, orchestrating multi-step operations. It also enforces per-VM operation serialization — a token-based `[UUID: UUID]` dictionary maps each VM to its current operation token and rejects concurrent requests with `VMLifecycleCoordinator.LifecycleError.operationInProgress`. `stop`/`forceStop` bypass serialization entirely — they clear the token *before* calling the service, which invalidates any in-flight operation's `defer` guard and prevents stale removals.

**Why:** macOS VM installation is a multi-step process (download IPSW → create platform files → configure VM → install). Putting this in `VMLibraryViewModel` would bloat it with orchestration logic. The coordinator keeps the view model focused on list management and selection, while the coordinator handles operational complexity. Operation serialization prevents undefined behavior from concurrent `VZVirtualMachine` calls (e.g., double-start or pause-during-start).

**Alternatives:** Fat view model (simpler structure but harder to test and maintain), or individual operation objects (more granular but more types to manage).

### 7. Native NSToolbar with observation-driven validation

**What:** The main window and display window use `NSToolbar` with `NSToolbarDelegate` creating native `NSToolbarItem`s. Shared toolbar items (lifecycle, suspend, display, settings toggle) are managed by `VMToolbarManager`, a `@MainActor` `NSObject` subclass that handles item creation, state updates, and action routing for both controllers. Each controller configures it with an `instanceProvider` closure and a `Configuration` struct that captures per-controller differences (identifier strings, `isPreparing` checks, display capability gating, presence of the settings toggle). Toolbar state is driven by the shared `observeRecurring` helper (see Utilities), directly setting `isEnabled` on subitems on change. All toolbar items — both `NSToolbarItemGroup`s and plain `NSToolbarItem`s whose enabled state is driven manually — use `autovalidates = false`, because `NSToolbarItemValidation` returns `true` for any shared identifier when a VM is selected, and AppKit's autovalidation would otherwise fight the observation-driven `isEnabled` writes and produce a visible flicker on selection changes. When an item swaps its image/label based on state (Start↔Resume, Pop Out↔Pop In, Show↔Hide Settings), the mutation is guarded behind a label-equality check so no-op updates don't trigger an AppKit redraw.

**Why:** Native `NSToolbarItem`s provide reliable layout, proper `.sidebarTrackingSeparator` support, and standard macOS toolbar appearance. The `observeRecurring` helper handles re-registration after each change and `[weak self]` teardown uniformly across every window controller, so toolbar updates stay reactive without SwiftUI and without duplicating the observation-loop boilerplate at each site. The shared `VMToolbarManager` eliminates ~150 lines of duplicated toolbar logic between `MainWindowController` and `VMDisplayWindowController`, ensuring toolbar changes are applied in one place.

**Alternatives:** SwiftUI `.toolbar` modifiers on a hosting controller — simpler declarative API but caused persistent layout issues with grouped items and sidebar tracking.

## Helper Targets

Three standalone targets are built alongside the main app — two CLI tools and one unit-test bundle:

- **KernovaRelaunchHelper** — Embedded in `Contents/MacOS/`. A watchdog that monitors the main app's PID and relaunches it after TCC-forced terminations. Launched by `AppDelegate` during quit when a TCC revocation is detected.

- **KernovaGuestAgent** — Not embedded directly. Runs inside macOS VMs and maintains three long-lived vsock connections to the host: an always-on control channel (`VsockGuestControlAgent` on port 49154 carrying the version handshake, bidirectional heartbeat, and the inbound `PolicyUpdate` push), log forwarding (`VsockHostConnection` on port 49153), and bidirectional clipboard sync (`VsockGuestClipboardAgent` on port 49152). All three connections are independent — a disconnect on one doesn't take the others down — and all share a `VsockGuestClient` helper that owns the connect/retry/serve loop. The log + clipboard agents start in a default-disabled state (paused at the `VsockGuestClient` level so no connect attempts run); they're enabled when the control agent receives the host's first `PolicyUpdate` and routes it via an `onPolicy` closure to `vsockConnection.setEnabled(_:)` and `clipboardAgent.setEnabled(_:)`. Disabling either capability discards buffered records and pauses the reconnect loop, so the guest stops generating traffic rather than relying on the host to ignore it. The clipboard agent polls `NSPasteboard.general` at 500 ms and announces changes to the host via `ClipboardOffer` frames; on inbound offers it requests the bytes and writes them to the local pasteboard. The agent depends on the local `KernovaProtocol` SPM package for the wire types and channel implementation. Packaged into a disk image at build time by the "Package Guest Agent DMG" Run Script build phase. The disk image (containing the binary, `install.command`, `uninstall.command`, and a LaunchAgent plist) is placed in `Contents/Resources/KernovaGuestAgent.dmg`. At runtime, the "Install Guest Agent..." menu item in the Virtual Machine menu attaches it to a guest VM as USB mass storage. The guest user runs `install.command` to install the agent as a LaunchAgent in user-space (`~/Library/Application Support/Kernova/`). The vsock reconnect loop uses a flat 5s retry interval; `SO_RCVTIMEO` / `SO_SNDTIMEO` are set to 30 s as a safety net against wedged read/write calls. The build number is injected via `INFOPLIST_PREPROCESS`: a pre-Sources build phase ("Set Build Number from Git") writes `#define AGENT_BUILD_NUMBER` (set to the git commit count scoped to `KernovaGuestAgent/`) to a header in `DERIVED_FILE_DIR`, and the explicit `Info.plist` references that macro for `CFBundleVersion`. The preprocessed plist is embedded in the binary via `CREATE_INFOPLIST_SECTION_IN_BINARY`.

- **KernovaGuestAgentTests** — Standalone unit-test bundle (no `TEST_HOST` / `BUNDLE_LOADER`) that covers the agent-side classes. Because `KernovaGuestAgent` is an executable tool target (not a framework), its symbols are not linkable — the test bundle instead compiles the agent's Swift source files directly (all except `main.swift`, `Info.plist`, and the shell scripts, excluded via `PBXFileSystemSynchronizedBuildFileExceptionSet`). This direct compilation makes all `internal` members accessible without `@testable import`, which is unavailable for tool targets. Three agent classes required light testability seams: `VsockGuestClient` gained a `socketProvider` closure injection point and a parameterized `retryInterval` (default unchanged at 5 s); `VsockGuestClipboardAgent` gained a `Pasteboard` protocol (with `NSPasteboard` conformance) and injected `client`/`pasteboard` init parameters; `VsockHostConnection` lifted `pendingLogs`, `lock`, `bufferFrame`, `flushPendingLogs`, and `logBufferLimit` from `private` to internal. Shared test helpers live in `TestHelpers.swift` (socket-pair factories, `waitUntil`, `AsyncGate`, `nextFrame`, `awaitFirst`, `AtomicInt`, frame factories). Non-parallelizable in the scheme because each test worker loads the agent sources which include global state (`VsockLogBridge.connection`); tests share one runner process.

## Dependencies

| Framework | Role |
|-----------|------|
| **Virtualization** | Core VM lifecycle — create, configure, start, stop, pause, resume VMs. Requires `com.apple.security.virtualization` entitlement. |
| **AppKit** | All UI — window management (`NSWindowController`, `NSSplitViewController`), toolbar (`NSToolbar`), menus, app delegate, sidebar (`NSOutlineView`), detail pane / settings / wizard (`NSViewController`s), and the VM display (`VMDisplayBackingView`). The app target imports no SwiftUI. |
| **Observation** | `@Observable` macro for `VMInstance`, `VMLibraryViewModel`, `VMCreationViewModel`. |
| **UniformTypeIdentifiers** | `UTType` declaration for `.kernova` VM bundles. |
| **os** | Unified logging via `os.Logger`. |
| **CryptoKit** | SHA-256 digest of the bundle path → deterministic UUID for the synthesized main disk (see `ConfigurationBuilder.stableMainDiskID(forBundleAt:)`). Apple system framework. |
| **SwiftProtobuf** | Wire-protocol codegen + runtime, consumed only by the local `KernovaProtocol` SPM package. From `apple/swift-protobuf` — the lone non-system-framework dependency, accepted because it is Apple-published. |

No third-party (non-Apple) package dependencies. No CocoaPods or Carthage.

## Testing

Test patterns, the test-plan wiring, the event-driven-waits policy, and coverage gaps are documented in [docs/testing.md](docs/testing.md). Per-suite scope is annotated inline in the [directory tree](#directory-structure) above.
