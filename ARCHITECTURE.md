# Architecture

## Overview

Kernova is a macOS application for creating and managing virtual machines via Apple's Virtualization.framework, supporting both macOS and Linux guests. It is built as an AppKit app hosting SwiftUI views, targeting macOS 26 (Tahoe) with Swift 6 strict concurrency. There are no external package dependencies — the app uses only Apple system frameworks.

## Directory Structure

```
Kernova/
├── App/                                # App lifecycle and window management
│   ├── AppDelegate.swift               # NSApplicationDelegate — startup, window tracking, menu, suspend-on-quit
│   ├── MainWindowController.swift      # NSSplitViewController + NSToolbar with native items
│   ├── VMDisplayWindowController.swift  # Per-VM display window (pop-out or fullscreen), auto-closes on VM stop
│   ├── DetailContainerViewController.swift # Layers AppKit VM display over SwiftUI detail content; respects per-instance detailPaneMode
│   ├── VMToolbarManager.swift          # Shared toolbar logic for lifecycle, suspend, display, and settings-toggle items
│   ├── SerialConsoleWindowController.swift # Per-VM serial console window, auto-closes on VM stop
│   ├── SerialConsoleContentViewController.swift # Pure AppKit serial terminal + status bar (contains SerialTextView)
│   ├── ClipboardWindowController.swift   # Per-VM clipboard sharing window, auto-closes on VM stop
│   ├── ClipboardContentViewController.swift # Pure AppKit clipboard text editor + status bar
│   └── Info.plist                        # App configuration and metadata
├── Models/                             # Data types — all value types or @MainActor-isolated
│   ├── VMConfiguration.swift           # Codable/Sendable struct persisted as config.json per VM bundle
│   ├── VMInstance.swift                # @Observable runtime wrapper: VMConfiguration + VZVirtualMachine + VMStatus
│   ├── VMBundleLayout.swift            # Sendable struct centralizing file paths within a .kernova bundle
│   ├── VMStatus.swift                  # Enum: stopped, starting, running, paused, saving, restoring, installing, error
│   ├── VMBootMode.swift                # Enum: macOS, efi, linuxKernel
│   ├── VMGuestOS.swift                 # Enum: macOS, linux
│   ├── MacOSInstallState.swift         # Tracks two-phase macOS installation progress (download + install)
│   └── KernovaUTType.swift             # UTType declaration for .kernova bundle
├── Services/                           # Business logic — stateless or @MainActor
│   ├── ConfigurationBuilder.swift      # VMConfiguration → VZVirtualMachineConfiguration (3 boot paths)
│   ├── VirtualizationService.swift     # VM lifecycle: start/stop/pause/resume/save/restore (@MainActor)
│   ├── VMStorageService.swift          # CRUD for VM bundles + cloning (Sendable struct)
│   ├── DiskImageService.swift          # Creates ASIF disk images from bundled templates (Sendable struct)
│   ├── MacOSInstallService.swift       # Drives macOS guest install via VZMacOSInstaller (@MainActor)
│   ├── IPSWService.swift               # Fetches/downloads macOS restore images (Sendable struct)
│   ├── SystemSleepWatcher.swift        # Observes system sleep/wake, triggers VM pause/resume
│   ├── SpiceAgentProtocol.swift       # SPICE agent wire format: VDI chunks, message headers, clipboard types
│   ├── ClipboardServicing.swift       # Protocol shared by Spice + Vsock clipboard implementations
│   ├── SpiceClipboardService.swift    # Linux clipboard: pipe I/O, SPICE protocol state machine (@MainActor)
│   ├── VsockClipboardService.swift    # macOS clipboard: vsock-based offer/request/data state machine (@MainActor)
│   └── Protocols/                      # Service protocol abstractions for DI and testing
│       ├── VirtualizationProviding.swift
│       ├── VMStorageProviding.swift
│       ├── DiskImageProviding.swift
│       ├── MacOSInstallProviding.swift
│       └── IPSWProviding.swift
├── ViewModels/                         # Observable view models and coordinators
│   ├── VMLibraryViewModel.swift        # Central view model — owns [VMInstance], delegates to coordinator
│   ├── VMLifecycleCoordinator.swift    # Owns services, orchestrates multi-step operations (@MainActor)
│   ├── VMCreationViewModel.swift       # Drives the multi-step VM creation wizard
│   ├── IPSWDownloadViewModel.swift     # Manages IPSW download state for macOS VM creation
│   └── VMDirectoryWatcher.swift        # DispatchSource monitor for external filesystem changes
├── Views/                              # SwiftUI views
│   ├── VMInstance+Display.swift        # Display-layer extension: cold-paused vs live-paused distinction
│   ├── Sidebar/
│   │   ├── SidebarView.swift           # VM list with selection, double-click-to-start, and context menus
│   │   └── VMRowView.swift             # Individual VM row (name, status, inline rename)
│   ├── Detail/
│   │   ├── MainDetailView.swift        # Detail pane wrapper — selection switch, creation sheet, error alert
│   │   ├── VMDetailView.swift          # VM detail — console/settings switch (honors detailPaneMode), confirmation alerts
│   │   ├── VMSettingsView.swift        # VM configuration editor; supports read-only mode when the VM is running
│   │   └── MacOSInstallProgressView.swift # Two-phase install progress (download + install)
│   ├── Console/
│   │   ├── VMConsoleView.swift         # Placeholder for non-inline display states (popped out, fullscreen, suspended, no display)
│   │   ├── VMDisplayBackingView.swift  # Pure AppKit VM display with pause/transition overlays
│   │   └── RemovableMediaPopoverView.swift # Toolbar popover for runtime USB attach/eject
│   └── Creation/
│       ├── VMCreationWizardView.swift  # Multi-step wizard container
│       ├── OSSelectionStep.swift       # Step 1: Choose macOS or Linux
│       ├── IPSWSelectionStep.swift     # Step 2 (macOS): Choose restore image
│       ├── BootConfigStep.swift        # Step 2 (Linux): Configure boot method
│       ├── ResourceConfigStep.swift    # Step 3: CPU, memory, disk size
│       └── ReviewStep.swift            # Step 4: Review and create
├── Utilities/
│   ├── DataFormatters.swift            # Human-readable formatting for bytes, CPU counts, etc.
│   ├── FileManagerExtensions.swift     # FileManager convenience methods
│   ├── NSImageExtensions.swift         # Nil-safe SF Symbol image loading
│   ├── NSViewExtensions.swift          # Full-size subview constraint helper
│   └── ObservationLoop.swift           # observeRecurring(track:apply:) helper wrapping withObservationTracking
└── Resources/
    ├── Assets.xcassets/                # App icons and image assets
    └── Kernova.entitlements            # com.apple.security.virtualization entitlement

DiskTemplates/                             # Bundled ASIF disk image templates (22 lzfse-compressed files)
                                           # Decompressed at VM creation time by DiskImageService

KernovaRelaunchHelper/
└── main.swift                          # Lightweight CLI watchdog for TCC-forced restarts

KernovaGuestAgent/                      # Guest-side vsock agent for macOS VMs + DMG packaging resources
├── main.swift                          # Entry point: signal handling, starts log + clipboard agents
├── RawSocketOps.swift                  # Protocol + DarwinRawSocketOps wrapping BSD syscalls for testability
├── VsockGuestClient.swift              # Generic connect/retry/serve loop — shared by log and clipboard
├── VsockHostConnection.swift           # Log-forwarding agent on port 49153 (uses VsockGuestClient)
├── VsockGuestClipboardAgent.swift      # Clipboard sync agent on port 49152 (uses VsockGuestClient)
├── VsockPorts.swift                    # Guest-side port registry (mirrors Kernova/Services/VsockPorts.swift)
├── VsockLogBridge.swift                # Static handle so KernovaLogger can hand records to VsockHostConnection
├── KernovaLogger.swift                 # Drop-in os.Logger wrapper that mirrors records to host
├── KernovaLogMessage.swift             # Custom interpolation supporting OSLogPrivacy-shaped privacy attrs
├── Info.plist                          # Explicit Info.plist with preprocessor macro for CFBundleVersion
├── install.command                     # Guest-side installer: copies binary, registers LaunchAgent
├── uninstall.command                   # Guest-side uninstaller: stops agent, removes files
└── com.kernova.agent.plist             # LaunchAgent template (__INSTALL_DIR__ replaced at install time)

KernovaProtocol/                        # SPM package: extensible vsock wire protocol shared host <-> guest
├── Package.swift                       # Swift 6 package, depends on apple/swift-protobuf
├── Proto/
│   └── kernova.proto                   # Frame envelope + Hello + Error (clipboard/log payloads added later)
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
├── Mocks/                              # Mock service implementations (6 files)
│   ├── MockVirtualizationService.swift
│   ├── SuspendingMockVirtualizationService.swift
│   ├── MockVMStorageService.swift
│   ├── MockDiskImageService.swift
│   ├── MockMacOSInstallService.swift
│   └── MockIPSWService.swift
├── VMConfigurationTests.swift          # 43 tests for VMConfiguration
├── VMToolbarManagerTests.swift          # Toolbar manager item creation and state update tests
├── VMConfigurationCloneTests.swift     # Clone-specific configuration tests
├── VMLibraryViewModelTests.swift       # 39 tests for the central view model
├── VMCreationViewModelTests.swift      # 44 tests for the creation wizard
├── VMLifecycleCoordinatorTests.swift   # Coordinator orchestration tests
├── VMInstanceTests.swift               # Runtime instance behavior tests
├── ConfigurationBuilderTests.swift     # VZ configuration translation tests
├── VirtualizationServiceTests.swift    # VM lifecycle operation tests
├── VMStorageServiceTests.swift         # Storage CRUD tests
├── VMBundleLayoutTests.swift           # Bundle path calculation tests
├── VMStatusTests.swift                 # Status enum behavior tests
├── VMStatusSerialConsoleTests.swift    # Serial console status tests
├── VMBootModeTests.swift               # Boot mode enum tests
├── VMGuestOSTests.swift                # Guest OS enum tests
├── MacOSInstallStateTests.swift        # Install state tracking tests
├── SpiceAgentProtocolTests.swift       # SPICE wire format serialization/deserialization tests
├── DataFormattersTests.swift           # Formatting utility tests
└── NSImageExtensionsTests.swift        # SF Symbol loading utility tests

KernovaGuestAgentTests/                 # Unit tests for the guest agent (standalone xctest bundle — no TEST_HOST)
│                                       # Compiles KernovaGuestAgent source files directly (except main.swift)
│                                       # so internal members are accessible without @testable import.
│                                       # See Helper Targets section for the source-compilation rationale.
├── TestHelpers.swift                   # Shared helpers: makeRawSocketPair, makeChannelPair, waitUntil,
│                                       # nextFrame, awaitFirst, AtomicInt, frame factories (makeLogFrame etc.)
├── RawSocketOpsMock.swift              # Pop-from-front scripted mock for RawSocketOps; records all calls
├── KernovaLogMessageTests.swift        # Privacy-redaction matrix for KernovaLogMessage interpolations
├── VsockHostConnectionTests.swift      # Log ring-buffer cap, partial-flush re-enqueue, forwardLog live-channel paths
├── VsockGuestClientTests.swift         # Connect/retry/stop lifecycle; socket-factory injection; BSD-syscall paths
└── VsockGuestClipboardAgentTests.swift # Echo suppression, reconnect reset, offer/request/data flow
```

**Total: 57 source files + 2 helpers, 32 test files (24 suites + 6 mocks + 1 test-helpers + 1 test-mock).**

*Note: `ContentView.swift` was removed when `NavigationSplitView` was replaced by `NSSplitViewController` in `MainWindowController`. Its responsibilities were split between `MainWindowController` (toolbar, split view) and `MainDetailView` (detail switching, sheets, alerts).*

## Component Map

### App Layer

**Files:** `AppDelegate.swift`, `MainWindowController.swift`, `DetailContainerViewController.swift`, `VMDisplayWindowController.swift`, `VMToolbarManager.swift`, `SerialConsoleWindowController.swift`, `ClipboardWindowController.swift`

`AppDelegate` is the entry point. It creates the `VMLibraryViewModel` and `VMLifecycleCoordinator`, opens the main window, and manages the lifecycle of all windows. It tracks window controllers in dictionaries keyed by VM UUID, enabling one-to-many relationships (a VM can have a main view, a fullscreen window, and a serial console open simultaneously). `AppDelegate` also handles:
- The application menu (including VM-specific actions, Force Stop with `canForceStop` validation, and Window > Show Library with Cmd+0)
- Suspend-on-quit behavior (suspending VMs before termination)
- Conditional termination: `applicationShouldTerminateAfterLastWindowClosed` returns `false` when VMs are active or fullscreen windows exist, preventing premature exit on fullscreen-to-inline transitions
- Dock icon reopen: `applicationShouldHandleReopen` restores the main window when clicked with no visible windows, or when clicked while the app is already active and the library window has been closed
- Fullscreen exit recovery: closing a fullscreen window automatically re-shows the main library window via `showLibrary(_:)`
- TCC relaunch: when macOS force-quits the app for a TCC permission change while VMs are running, `applicationShouldTerminate` launches `KernovaRelaunchHelper` (a CLI embedded in `Contents/MacOS/`) before beginning the async VM save. The helper monitors the app's PID via `DispatchSource` and relaunches the app via `NSWorkspace` after it exits, working around macOS's TCC relaunch timeout. TCC is positively identified by intercepting the `kAEQuitApplication` Apple Event and checking if the sender is the Privacy & Security settings extension (`com.apple.settings.PrivacySecurity.extension`).

`MainWindowController` creates an `NSWindow` with an `NSSplitViewController` as the content view controller. The split view has two panes: a sidebar (`NSSplitViewItem(sidebarWithViewController:)` wrapping `SidebarView`) and a detail pane (wrapping `MainDetailView`). Both panes use `NSHostingController` to embed SwiftUI content. An `NSToolbar` with native `NSToolbarItem`s provides lifecycle controls (Start/Resume, Pause, Stop), Suspend, Fullscreen, New VM, and a Show/Hide Settings toggle that lets the user view the (read-only) settings form while a VM is running. Shared toolbar items (lifecycle, suspend, display, settings toggle) are managed by `VMToolbarManager`; the New VM button and sidebar items remain controller-specific. The settings toggle only appears in the main window — the pop-out display window passes `settingsToggleID: nil`. Toolbar state is observed via `withObservationTracking` and items are validated through `NSToolbarItemValidation`. The `.fullSizeContentView` style mask and `.sidebarTrackingSeparator` preserve the full-height sidebar appearance matching Mail/Finder.

### Models

**Files:** `VMConfiguration.swift`, `VMInstance.swift`, `VMBundleLayout.swift`, `VMStatus.swift`, `VMBootMode.swift`, `VMGuestOS.swift`, `MacOSInstallState.swift`, `KernovaUTType.swift`

The model layer has two key types:

- **`VMConfiguration`** is the persisted identity of a VM. It's a `Codable` + `Sendable` struct written as `config.json` inside each VM bundle. It holds: name, UUID, guest OS type, boot mode, CPU/memory/disk settings, display configuration (including `lastFullscreenDisplayID` for remembering which display a VM was fullscreen on), network settings, audio settings (`microphoneEnabled` — opt-in host microphone passthrough, defaults to off), and OS-specific fields (macOS hardware model data, Linux kernel/initrd/cmdline paths).

- **`VMInstance`** is the runtime representation. It's an `@Observable` `@MainActor` class that wraps a `VMConfiguration`, an optional `VZVirtualMachine`, and a `VMStatus`. It references the VM's bundle path and provides computed properties for disk image, aux storage, and save file locations via `VMBundleLayout`. A view-layer extension (`VMInstance+Display.swift`) provides display properties (`statusDisplayName`, `statusDisplayColor`, `statusToolTip`) that distinguish preparing VMs (shown as "Cloning…"/"Importing…" in orange with a spinner), cold-paused VMs (state saved to disk, shown as "Suspended" in orange), and live-paused VMs (in memory, shown as "Paused" in yellow). The `PreparingOperation` enum (`.cloning`, `.importing`) provides display labels, cancel labels, and alert titles for preparing states. The `PreparingState` struct bundles the operation and its cancellable task into a single optional (`preparingState`) — when non-nil the instance is preparing, and `isPreparing` is a computed convenience. A per-instance `detailPaneMode` (enum `DetailPaneMode { case display, settings }`, defaulting to `.display`) lets the user toggle, while the VM is running, between the live display and a read-only view of the settings form; the mode is ignored when the VM is stopped (settings are always shown then).

`VMBundleLayout` is a `Sendable` struct that takes a bundle root path and provides all derived file paths (disk image, aux storage, save file, serial log, etc.), keeping path logic centralized.

The remaining models are enums: `VMStatus` (stopped/starting/running/paused/saving/restoring/installing/error), `VMBootMode` (macOS/efi/linuxKernel), `VMGuestOS` (macOS/linux), and `MacOSInstallState` (tracking download and install phases with progress). `VMStatus` provides computed properties for state checks (`canStart`, `canStop`, `canForceStop`, `canPause`, `canResume`, `canSave`, `canEditSettings`, `canRename`, `isTransitioning`, `isActive`). `canForceStop` covers all states where a `VZVirtualMachine` may exist and need forceful termination (running, paused, starting, saving, restoring).

### Services

**Files:** `ConfigurationBuilder.swift`, `VirtualizationService.swift`, `VMStorageService.swift`, `DiskImageService.swift`, `MacOSInstallService.swift`, `IPSWService.swift`, `SpiceAgentProtocol.swift`, `ClipboardServicing.swift`, `SpiceClipboardService.swift`, `VsockClipboardService.swift`, `VsockListenerHost.swift`, `VsockGuestLogService.swift`, `VsockPorts.swift`

**Protocols:** `VirtualizationProviding`, `VMStorageProviding`, `DiskImageProviding`, `MacOSInstallProviding`, `IPSWProviding`

Services are split by concurrency requirements:

- **`@MainActor` services** (interact with `VZVirtualMachine`):
  - `VirtualizationService` — start, stop, pause, resume, save state, restore state
  - `MacOSInstallService` — loads restore image, creates platform files (aux storage, hardware model, machine identifier), runs `VZMacOSInstaller` with KVO progress tracking

- **`Sendable` struct services** (no mutable state, safe to call from anywhere):
  - `VMStorageService` — creates/deletes/lists VM bundle directories at `~/Library/Application Support/Kernova/VMs/` and handles cloning (deep copy with new UUID)
  - `DiskImageService` — creates ASIF disk images by decompressing bundled lzfse-compressed templates (sandbox-safe, no subprocess)
  - `IPSWService` — fetches available macOS restore images from Apple's catalog and downloads IPSW files

- **`SystemSleepWatcher`** — `@MainActor` observer class that monitors `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`. Follows the same pattern as `VMDirectoryWatcher`: callback-driven, `nonisolated(unsafe)` for observer tokens, `start()`/`deinit` lifecycle. Owned by `VMLibraryViewModel`, which uses it to auto-pause running VMs before sleep and resume them on wake.

- **`ConfigurationBuilder`** — Translates a `VMConfiguration` into a `VZVirtualMachineConfiguration`. Handles three boot paths: `VZMacOSBootLoader` (macOS), `VZEFIBootLoader` (EFI/UEFI), and `VZLinuxBootLoader` (direct kernel boot). Configures CPU, memory, storage, network, display, keyboard, trackpad, and audio devices. When `clipboardSharingEnabled` is set on a Linux guest, configures a `VZVirtioConsoleDeviceConfiguration` with a SPICE-named port using raw `VZFileHandleSerialPortAttachment` pipes (not `VZSpiceAgentPortAttachment`); macOS guests instead carry clipboard over the vsock device. For macOS guests it always appends a `VZVirtioSocketDeviceConfiguration` so the host can install vsock listeners (log + clipboard) against the live device once the VM is created. Resolves symlinks on user-supplied paths (shared directories, kernel/initrd, ISO images) and validates them before passing to VZ. File paths (kernel, initrd, ISO) are checked for existence and rejected if they point to directories. Shared directory validation checks existence, is-directory, readability, and writability (for read-write shares) against the resolved path.

- **`SpiceAgentProtocol`** — Pure data types and parsing for the SPICE agent wire format. Defines VDI chunk headers, VDAgent message headers, clipboard message types, and capability bitmasks. Includes `SpiceMessageBuilder` (builds wire-ready messages with a `port` parameter defaulting to `serverPort` for host-side use) and `SpiceAgentParser` (incremental parser handling fragmented data across multiple pipe reads). Fully `Sendable`, no I/O. Used only by the host-side `SpiceClipboardService` (Linux clipboard transport) — macOS guests now use vsock instead, so the file is no longer multi-target.

- **`ClipboardServicing`** — `@MainActor` protocol covering the public surface (`clipboardText`, `isConnected`, `start()`, `stop()`, `grabIfChanged()`) shared by both clipboard implementations. `VMInstance.clipboardService` holds the existential, so the clipboard window controllers don't branch on transport.

- **`SpiceClipboardService`** — `@MainActor` `ClipboardServicing` implementation for Linux guests. Reads from the guest pipe on a background GCD queue, parses messages via `SpiceAgentParser`, and exposes `clipboardText` (observable, editable by the UI) and `isConnected`. When the clipboard window loses focus, `grabIfChanged()` sends a `CLIPBOARD_GRAB` if the text was edited. Uses raw pipes rather than `VZSpiceAgentPortAttachment` so clipboard data flows through the gated UI instead of the host `NSPasteboard`.

- **`VsockClipboardService`** — `@MainActor` `ClipboardServicing` implementation for macOS guests, layered on `VsockChannel`. Sends `Hello` on start; outbound clipboard changes are announced as `ClipboardOffer` with a monotonically increasing `generation`, then the guest pulls the bytes via `ClipboardRequest` / `ClipboardData`. Inbound flow is symmetrical (offer → request → data). Stale generations are detected by both sides so a `ClipboardData` reply that races a newer offer is dropped rather than overwriting fresher state. The service is constructed lazily by the vsock clipboard listener when the guest connects, so `VMInstance.clipboardService` may be nil until then.

- **`VsockListenerHost`** — `@MainActor` wrapper around `VZVirtioSocketListener` bound to one vsock port. The nonisolated `VZVirtioSocketListenerDelegate` callback dups the connection's file descriptor and bridges back to MainActor before constructing a `VsockChannel` and handing it to a caller-supplied closure. One instance per service; multiple coexist on the same `VZVirtioSocketDevice`.

- **`VsockGuestLogService`** — `@MainActor` consumer that owns one accepted `VsockChannel` for the lifetime of a guest connection. Forwards `LogRecord` frames through a `GuestLogEmitter` abstraction (default `OSLogGuestLogEmitter`, subsystem `com.kernova.guest`); guest log levels map 1:1 onto `os.Logger` methods. `Hello` and `Error` frames go to the host's own diagnostic logger instead of the guest stream. The service self-terminates on EOF.

- **`VsockPorts`** — Central registry of port assignments (`KernovaVsockPort.clipboard = 49152`, `KernovaVsockPort.log = 49153`) so each service gets its own listener on a distinct port instead of in-band multiplexing.

All service implementations conform to protocols defined in `Services/Protocols/`. This enables full dependency injection — tests use mock implementations that track call counts and support error injection.

### ViewModels

**Files:** `VMLibraryViewModel.swift`, `VMLifecycleCoordinator.swift`, `VMCreationViewModel.swift`, `IPSWDownloadViewModel.swift`, `VMDirectoryWatcher.swift`

- **`VMLibraryViewModel`** is the central `@Observable` view model. It owns the array of `VMInstance`s and handles list-level operations: add, remove, rename, reorder, selection tracking. VM order is user-customizable via drag-and-drop in the sidebar, persisted as a UUID array in `UserDefaults` (key `"vmOrder"`). VMs not in the custom order (newly created/discovered) sort after ordered VMs by `createdAt`. For lifecycle operations (start, stop, install), it delegates to `VMLifecycleCoordinator`. Clone and import operations use a "phantom row" pattern: a `VMInstance` with `isPreparing = true` appears immediately in the sidebar with a spinner while the file copy runs asynchronously via `Task.detached`. The `hasPreparing` computed property enforces serialization — only one clone/import at a time. Cancellation removes the phantom row, cancels the task, and cleans up partial files on disk. Force-stop is surfaced via `confirmForceStop()` which presents a confirmation dialog.

- **`VMLifecycleCoordinator`** is an `@MainActor` coordinator that owns the lifecycle services (`VirtualizationService`, `MacOSInstallService`, `IPSWService`). It orchestrates multi-step operations like macOS installation (which involves IPSW download → platform file creation → VM configuration → installation). This separation keeps `VMLibraryViewModel` focused on list management. The coordinator enforces **per-VM operation serialization** — at most one lifecycle operation can be in flight for a given VM at any time; concurrent requests are rejected with `VMLifecycleCoordinator.LifecycleError.operationInProgress`. `stop` and `forceStop` bypass serialization entirely (clearing the active-operation token before calling the service) so users can always cancel hung operations.

- **`VMCreationViewModel`** drives the multi-step creation wizard. It tracks the current step, validates inputs at each stage, and produces a `VMConfiguration` + disk image on completion.

- **`IPSWDownloadViewModel`** manages IPSW download state (progress, cancellation) during macOS VM creation.

- **`VMDirectoryWatcher`** uses `DispatchSource.makeFileSystemObjectSource` to monitor the VMs directory for external changes (e.g., a user restoring a VM from Trash via Finder). When changes are detected, it triggers reconciliation in `VMLibraryViewModel` to sync the in-memory list with disk.

- **`SystemSleepWatcher`** (see Services section) is also owned by `VMLibraryViewModel`, triggering `pauseAllForSleep()` and `resumeAllAfterWake()` on system sleep/wake events. Auto-paused VMs are tracked in `sleepPausedInstanceIDs` so user-paused VMs are not accidentally resumed.

### Views

**Files:** 16 SwiftUI views + 1 AppKit view across 4 subdirectories

Views observe `VMLibraryViewModel` and individual `VMInstance`s via the Observation framework. The view hierarchy (AppKit owns the structural layout, SwiftUI renders content):

```
NSSplitViewController (MainWindowController)
├── Sidebar pane: SidebarView → VMRowView (per VM)
└── Detail pane: DetailContainerViewController
    ├── VMDisplayBackingView (AppKit, layered on top — shown when VM running inline)
    │   └── VZVirtualMachineView + pause/transition overlays
    └── NSHostingController (SwiftUI, always present behind)
        └── MainDetailView → VMDetailView
            ├── VMConsoleView (placeholder when display is external, suspended, or unavailable)
            ├── VMSettingsView
            └── MacOSInstallProgressView
VMCreationWizardView (modal sheet on detail pane)
├── OSSelectionStep
├── IPSWSelectionStep / BootConfigStep
├── ResourceConfigStep
└── ReviewStep
SerialConsoleContentViewController → SerialTextView (in separate window)
```

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
    │                 ├── Sidebar: NSHostingController(SidebarView)
    │                 └── Detail:  DetailContainerViewController
    │                              ├── VMDisplayBackingView (AppKit VM display, layered on top)
    │                              └── NSHostingController(MainDetailView → VMDetailView)
    │
    ├── manages → VMDisplayWindowController (per VM)
    ├── manages → SerialConsoleWindowController (per VM)
    └── manages → ClipboardWindowController (per VM)

SwiftUI views ──observe──→ VMLibraryViewModel ──delegates──→ VMLifecycleCoordinator ──calls──→ Services
                           VMInstance (per VM)

SystemSleepWatcher ──sleep/wake──→ VMLibraryViewModel ──pause/resume──→ VMLifecycleCoordinator
```

### Utilities

**Files:** `DataFormatters.swift`, `FileManagerExtensions.swift`, `NSImageExtensions.swift`, `NSViewExtensions.swift`, `ObservationLoop.swift`

- `DataFormatters` — human-readable formatting for bytes (e.g., "107.4 GB"), CPU counts, etc.
- `FileManagerExtensions` — convenience methods on `FileManager`
- `NSImageExtensions` — `NSImage.systemSymbol(_:accessibilityDescription:)` for nil-safe SF Symbol loading with error logging
- `ObservationLoop` — `observeRecurring(track:apply:) -> ObservationLoop` helper that encapsulates the `withObservationTracking` + `Task { @MainActor }` + recursive re-register dance. Returns a cancel token stored by the caller; the loop stops when the token is deallocated or `cancel()` is called. Used by all 8 observation sites (`MainWindowController`, `VMDisplayWindowController`, `ClipboardWindowController`, `SerialConsoleWindowController`, `DetailContainerViewController`, `ClipboardContentViewController`, `SerialConsoleContentViewController`, `AppDelegate.observeForTermination`) so each site only declares *what* to track and *what* to do — not how to sustain the loop.

## Key Design Decisions

### 1. AppKit-owned structural layout

**What:** AppKit owns all structural elements: `NSSplitViewController` for sidebar/detail layout, `NSToolbar` with native `NSToolbarItem`s for the toolbar, and `NSWindow` for window management. SwiftUI renders content inside each pane via `NSHostingController`. The VM display (`VZVirtualMachineView`) is always managed by pure AppKit — in the detail pane, `DetailContainerViewController` layers the AppKit display on top of the SwiftUI content, and in pop-out/fullscreen windows, `VMDisplayWindowController` uses `VMDisplayBackingView` directly as the window's content view. All AppKit↔SwiftUI bridges are unidirectional (AppKit→SwiftUI only).

**Why:** The app needs precise control over native macOS chrome — toolbar items, split view behavior, sidebar collapsibility. SwiftUI's `NavigationSplitView` and `.toolbar` modifiers add an abstraction layer that creates fragile boundaries and toolbar layout limitations. With AppKit owning the structure, toolbar state is validated via `NSToolbarItemValidation`, sidebar appearance matches Mail/Finder, and there are no SwiftUI-toolbar quirks.

**Alternatives:** SwiftUI `NavigationSplitView` with `.toolbar` modifiers — simpler but encountered persistent toolbar layout issues. Pure SwiftUI with `WindowGroup`/`Window` — loses multi-window management needed for VM display windows.

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

- **KernovaGuestAgent** — Not embedded directly. Runs inside macOS VMs and maintains two long-lived vsock connections to the host: log forwarding (`VsockHostConnection` on port 49153) and bidirectional clipboard sync (`VsockGuestClipboardAgent` on port 49152). Both connections are independent — a disconnect on one doesn't take the other down — and both share a `VsockGuestClient` helper that owns the connect/retry/serve loop. The clipboard agent polls `NSPasteboard.general` at 500 ms and announces changes to the host via `ClipboardOffer` frames; on inbound offers it requests the bytes and writes them to the local pasteboard. The agent depends on the local `KernovaProtocol` SPM package for the wire types and channel implementation. Packaged into a disk image at build time by the "Package Guest Agent DMG" Run Script build phase. The disk image (containing the binary, `install.command`, `uninstall.command`, and a LaunchAgent plist) is placed in `Contents/Resources/KernovaGuestAgent.dmg`. At runtime, the "Install Guest Agent..." menu item in the Virtual Machine menu attaches it to a guest VM as USB mass storage. The guest user runs `install.command` to install the agent as a LaunchAgent in user-space (`~/Library/Application Support/Kernova/`). The vsock reconnect loop uses a flat 5s retry interval; `SO_RCVTIMEO` / `SO_SNDTIMEO` are set to 30 s as a safety net against wedged read/write calls. The build number is injected via `INFOPLIST_PREPROCESS`: a pre-Sources build phase ("Set Build Number from Git") writes `#define AGENT_BUILD_NUMBER` (set to the git commit count scoped to `KernovaGuestAgent/`) to a header in `DERIVED_FILE_DIR`, and the explicit `Info.plist` references that macro for `CFBundleVersion`. The preprocessed plist is embedded in the binary via `CREATE_INFOPLIST_SECTION_IN_BINARY`.

- **KernovaGuestAgentTests** — Standalone unit-test bundle (no `TEST_HOST` / `BUNDLE_LOADER`) that covers the agent-side classes. Because `KernovaGuestAgent` is an executable tool target (not a framework), its symbols are not linkable — the test bundle instead compiles the agent's Swift source files directly (all except `main.swift`, `Info.plist`, and the shell scripts, excluded via `PBXFileSystemSynchronizedBuildFileExceptionSet`). This direct compilation makes all `internal` members accessible without `@testable import`, which is unavailable for tool targets. Four agent classes required light testability seams: `VsockGuestClient` gained a `socketProvider` closure injection point and a parameterized `retryInterval` (default unchanged at 5 s), and its three static BSD-syscall helpers (`openVsockToHost`, `awaitConnectCompletion`, `applySocketTimeouts`) each accept a defaulted `ops: RawSocketOps = DarwinRawSocketOps()` parameter so tests can inject a scripted mock without real `AF_VSOCK` support; `VsockGuestClipboardAgent` gained a `Pasteboard` protocol (with `NSPasteboard` conformance) and injected `client`/`pasteboard` init parameters; `VsockHostConnection` lifted `pendingLogs`, `lock`, `bufferFrame`, `flushPendingLogs`, and `logBufferLimit` from `private` to internal. Shared test helpers live in `TestHelpers.swift` (socket-pair factories, `waitUntil`, `nextFrame`, `awaitFirst`, `AtomicInt`, frame factories); `RawSocketOpsMock.swift` provides the scripted mock for BSD-syscall injection. Non-parallelizable in the scheme because each test worker loads the agent sources which include global state (`VsockLogBridge.connection`); tests share one runner process.

## Dependencies

| Framework | Role |
|-----------|------|
| **Virtualization** | Core VM lifecycle — create, configure, start, stop, pause, resume VMs. Requires `com.apple.security.virtualization` entitlement. |
| **AppKit** | Window management (`NSWindowController`, `NSSplitViewController`), toolbar (`NSToolbar`), menus, app delegate. |
| **SwiftUI** | UI views (settings, sidebar, wizards), hosted in `NSHostingController` children within AppKit window controllers. VM display is pure AppKit via `VMDisplayBackingView`. |
| **Observation** | `@Observable` macro for `VMInstance`, `VMLibraryViewModel`, `VMCreationViewModel`, `IPSWDownloadViewModel`. |
| **UniformTypeIdentifiers** | `UTType` declaration for `.kernova` VM bundles. |
| **os** | Unified logging via `os.Logger`. |
| **SwiftProtobuf** | Wire-protocol codegen + runtime, consumed only by the local `KernovaProtocol` SPM package. From `apple/swift-protobuf` — the lone non-system-framework dependency, accepted because it is Apple-published. |

No third-party (non-Apple) package dependencies. No CocoaPods or Carthage.

## Test Coverage

### Well Covered

| Component | Tests | Notes |
|-----------|-------|-------|
| `VMConfiguration` | 47 tests + clone suite | Encoding/decoding, defaults, validation, all fields |
| `VMLibraryViewModel` | 74 tests | Add/remove/rename/reorder VMs, selection, auto-select on load, selection preservation on reload, delegation to coordinator, sleep/wake, clone/import phantom rows, cancel preparing, force-stop confirmation, stop escalation timing, custom order persistence |
| `VMCreationViewModel` | 44 tests | All wizard steps, validation, OS-specific paths |
| `VMLifecycleCoordinator` | Yes | Multi-step orchestration, error handling, service delegation, token-based operation serialization, stop/forceStop bypass, stale-token race condition coverage |
| `VMInstance` | Yes | Status transitions, configuration updates, bundle layout, preparing state display properties |
| `ConfigurationBuilder` | Yes | All three boot paths, device configuration, path validation (symlinks, missing kernel/initrd/ISO, directory rejection for file paths) |
| `VirtualizationService` | Yes | Start/stop/pause/resume via mock VZ objects |
| `VMStorageService` | Yes | CRUD operations, cloning |
| `VMBundleLayout` | Yes | Path derivation from bundle root |
| `VMStatus` | Yes | Enum behavior, transitions, `canForceStop` |
| `VMBootMode` | Yes | Enum cases and properties |
| `VMGuestOS` | Yes | Enum cases and properties |
| `MacOSInstallState` | Yes | Phase tracking, progress calculation |
| `VMToolbarManager` | 22 tests | Item creation, state updates, configuration flags, label toggling |
| `DataFormatters` | Yes | Byte formatting, CPU count formatting |
| `NSImageExtensions` | Yes | SF Symbol loading with known symbol validation |
| `SpiceAgentProtocol` | Yes | VDI chunk/message serialization round-trips, parser with multi-message feeds, partial data, unknown types, clientPort constant, port-parameterized builders |
| `VsockClipboardService` | 8 tests | Hello handshake, outbound offer dedup + monotonic generation, request-response, stale request/data drop, inbound offer-driven population |
| `KernovaLogMessage` | Yes | Full privacy-redaction matrix: `.public`/`.private`/`.sensitive`/`.auto`/default, generic fallback (String, Int, Bool), mixed interpolations, literal init |
| `VsockHostConnection` | Yes | Log ring-buffer cap (256 frames), FIFO ordering, oldest-drop-first eviction, flush-to-channel, partial-flush re-enqueue (index>0 and index=0), cap enforcement after re-enqueue, `forwardLog` live-channel paths |
| `VsockGuestClient` | Yes | Socket-factory injection, `liveChannel` lifecycle, stop-mid-connect abort, stop-mid-serve, idempotent start, stop-before-start no-op, nil-provider retry; BSD-syscall paths via `RawSocketOps` mock covering all five new failure branches (fcntl, non-EINPROGRESS connect, poll error/timeout/POLLHUP/getsockopt, deferred SO_ERROR, EINTR retry, restore failure) |
| `VsockGuestClipboardAgent` | Yes | Outbound offer on pasteboard change, echo suppression after host write, reconnect resets `lastSeenText`, stale-generation data drop, full offer/request/data round-trip |

### Mocked but Not Directly Tested

These services interact with system processes, the network, or VZ installer internals. They are fully mocked in other tests but don't have their own test suites against real implementations:

- `DiskImageService` — decompresses bundled templates (no subprocess; direct testing feasible but requires bundled resources in test target)
- `IPSWService` — makes network requests to Apple
- `MacOSInstallService` — requires a real `VZVirtualMachine` and restore image
- `SpiceClipboardService` — requires active SPICE pipe I/O (protocol parsing tested via `SpiceAgentProtocol` suite)

### Not Tested

- `VMDirectoryWatcher` — relies on `DispatchSource` file system monitoring
- `SystemSleepWatcher` — relies on `NSWorkspace` sleep/wake notifications (sleep/wake logic tested via `VMLibraryViewModel`)
- `IPSWDownloadViewModel` — wraps async download state
- `KernovaUTType` — static UTType declaration
- `FileManagerExtensions` — FileManager convenience methods
- All window controllers (`MainWindowController`, `VMDisplayWindowController`, `SerialConsoleWindowController`, `ClipboardWindowController`)
- `AppDelegate` — app lifecycle and window management
- All SwiftUI views

### Test Patterns

- **Framework:** Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest
- **Mocks:** 6 mock implementations conforming to service protocols, supporting call counting and error injection via `throwError` properties. Includes `SuspendingMockVirtualizationService` for testing operation serialization — suspends mid-operation to verify concurrent rejection and token-based race conditions. Relies on `@MainActor` cooperative scheduling (documented in the mock) and enforces single-suspension via `precondition`
- **Factories:** Shared helpers like `makeInstance()`, `makeViewModel()`, `makeCoordinator()` reduce setup duplication
- **Error paths:** Mocks support setting `throwError` to inject failures and verify error handling
