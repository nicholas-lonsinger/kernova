# Architecture

## Overview

Kernova is a macOS application for creating and managing virtual machines via Apple's Virtualization.framework, supporting both macOS and Linux guests. It is built as an AppKit app hosting SwiftUI views, targeting macOS 26 (Tahoe) with Swift 6 strict concurrency. There are no external package dependencies — the app uses only Apple system frameworks.

## Directory Structure

```
Kernova/
├── App/                                # App lifecycle and window management
│   ├── AppDelegate.swift               # NSApplicationDelegate — startup, window tracking, menu, save-on-quit
│   ├── MainWindowController.swift      # Primary NSSplitViewController hosting SwiftUI sidebar + detail
│   ├── FullscreenWindowController.swift # Per-VM fullscreen window, auto-closes on VM stop
│   └── SerialConsoleWindowController.swift # Per-VM serial console window
├── Models/                             # Data types — all value types or @MainActor-isolated
│   ├── VMConfiguration.swift           # Codable/Sendable struct persisted as config.json per VM bundle
│   ├── VMInstance.swift                # @Observable runtime wrapper: VMConfiguration + VZVirtualMachine + VMStatus
│   ├── VMBundleLayout.swift            # Sendable struct centralizing file paths within a .kernova bundle
│   ├── VMStatus.swift                  # Enum: stopped, starting, running, pausing, paused, stopping, error
│   ├── VMBootMode.swift                # Enum: macOS, efi, linuxKernel
│   ├── VMGuestOS.swift                 # Enum: macOS, linux
│   ├── MacOSInstallState.swift         # Tracks two-phase macOS installation progress (download + install)
│   └── KernovaUTType.swift             # UTType declaration for .kernova bundle
├── Services/                           # Business logic — stateless or @MainActor
│   ├── ConfigurationBuilder.swift      # VMConfiguration → VZVirtualMachineConfiguration (3 boot paths)
│   ├── VirtualizationService.swift     # VM lifecycle: start/stop/pause/resume/save/restore (@MainActor)
│   ├── VMStorageService.swift          # CRUD for VM bundles + cloning + migration (Sendable struct)
│   ├── DiskImageService.swift          # Creates ASIF disk images via hdiutil (Sendable struct)
│   ├── MacOSInstallService.swift       # Drives macOS guest install via VZMacOSInstaller (@MainActor)
│   ├── IPSWService.swift               # Fetches/downloads macOS restore images (Sendable struct)
│   ├── SystemSleepWatcher.swift        # Observes system sleep/wake, triggers VM pause/resume
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
│   ├── ContentView.swift               # Root SwiftUI view (sidebar + detail split)
│   ├── Sidebar/
│   │   ├── SidebarView.swift           # VM list with toolbar actions
│   │   └── VMRowView.swift             # Individual VM row (name, status, inline rename)
│   ├── Detail/
│   │   ├── VMDetailView.swift          # Main detail pane — toolbar + console/settings switch
│   │   ├── VMInfoView.swift            # VM information display
│   │   ├── VMSettingsView.swift        # VM configuration editor
│   │   └── MacOSInstallProgressView.swift # Two-phase install progress (download + install)
│   ├── Console/
│   │   ├── VMConsoleView.swift         # VM display container
│   │   ├── VMDisplayView.swift         # NSViewRepresentable wrapping VZVirtualMachineView
│   │   ├── SerialConsoleContentView.swift # Serial console content wrapper
│   │   └── SerialTerminalView.swift    # Terminal text view for serial output
│   └── Creation/
│       ├── VMCreationWizardView.swift  # Multi-step wizard container
│       ├── OSSelectionStep.swift       # Step 1: Choose macOS or Linux
│       ├── IPSWSelectionStep.swift     # Step 2 (macOS): Choose restore image
│       ├── BootConfigStep.swift        # Step 2 (Linux): Configure boot method
│       ├── ResourceConfigStep.swift    # Step 3: CPU, memory, disk size
│       └── ReviewStep.swift            # Step 4: Review and create
├── Utilities/
│   ├── DataFormatters.swift            # Human-readable formatting for bytes, CPU counts, etc.
│   └── FileManagerExtensions.swift     # FileManager convenience methods
└── Resources/
    ├── Assets.xcassets/                # App icons and image assets
    └── Kernova.entitlements            # com.apple.security.virtualization entitlement

KernovaTests/
├── Mocks/                              # Mock service implementations (5 files)
│   ├── MockVirtualizationService.swift
│   ├── MockVMStorageService.swift
│   ├── MockDiskImageService.swift
│   ├── MockMacOSInstallService.swift
│   └── MockIPSWService.swift
├── VMConfigurationTests.swift          # 43 tests for VMConfiguration
├── VMConfigurationCloneTests.swift     # Clone-specific configuration tests
├── VMLibraryViewModelTests.swift       # 39 tests for the central view model
├── VMCreationViewModelTests.swift      # 44 tests for the creation wizard
├── VMLifecycleCoordinatorTests.swift   # Coordinator orchestration tests
├── VMInstanceTests.swift               # Runtime instance behavior tests
├── ConfigurationBuilderTests.swift     # VZ configuration translation tests
├── VirtualizationServiceTests.swift    # VM lifecycle operation tests
├── VMStorageServiceTests.swift         # Storage CRUD and migration tests
├── VMBundleLayoutTests.swift           # Bundle path calculation tests
├── VMStatusTests.swift                 # Status enum behavior tests
├── VMBootModeTests.swift               # Boot mode enum tests
├── VMGuestOSTests.swift                # Guest OS enum tests
├── MacOSInstallStateTests.swift        # Install state tracking tests
└── DataFormattersTests.swift           # Formatting utility tests
```

**Total: 49 source files, 20 test files (15 suites + 5 mocks).**

## Component Map

### App Layer

**Files:** `AppDelegate.swift`, `MainWindowController.swift`, `FullscreenWindowController.swift`, `SerialConsoleWindowController.swift`

`AppDelegate` is the entry point. It creates the `VMLibraryViewModel` and `VMLifecycleCoordinator`, opens the main window, and manages the lifecycle of all windows. It tracks window controllers in dictionaries keyed by VM UUID, enabling one-to-many relationships (a VM can have a main view, a fullscreen window, and a serial console open simultaneously). `AppDelegate` also handles:
- The application menu (including VM-specific actions)
- Save-on-quit behavior (saving VM state before termination)
- Window restoration

`MainWindowController` hosts an `NSSplitViewController` where each pane is an `NSHostingController` wrapping SwiftUI views. This is the AppKit/SwiftUI bridge point.

### Models

**Files:** `VMConfiguration.swift`, `VMInstance.swift`, `VMBundleLayout.swift`, `VMStatus.swift`, `VMBootMode.swift`, `VMGuestOS.swift`, `MacOSInstallState.swift`, `KernovaUTType.swift`

The model layer has two key types:

- **`VMConfiguration`** is the persisted identity of a VM. It's a `Codable` + `Sendable` struct written as `config.json` inside each VM bundle. It holds: name, UUID, guest OS type, boot mode, CPU/memory/disk settings, display configuration, network settings, and OS-specific fields (macOS hardware model data, Linux kernel/initrd/cmdline paths).

- **`VMInstance`** is the runtime representation. It's an `@Observable` `@MainActor` class that wraps a `VMConfiguration`, an optional `VZVirtualMachine`, and a `VMStatus`. It references the VM's bundle path and provides computed properties for disk image, aux storage, and save file locations via `VMBundleLayout`.

`VMBundleLayout` is a `Sendable` struct that takes a bundle root path and provides all derived file paths (disk image, aux storage, save file, serial log, etc.), keeping path logic centralized.

The remaining models are enums: `VMStatus` (stopped/starting/running/pausing/paused/stopping/error), `VMBootMode` (macOS/efi/linuxKernel), `VMGuestOS` (macOS/linux), and `MacOSInstallState` (tracking download and install phases with progress).

### Services

**Files:** `ConfigurationBuilder.swift`, `VirtualizationService.swift`, `VMStorageService.swift`, `DiskImageService.swift`, `MacOSInstallService.swift`, `IPSWService.swift`

**Protocols:** `VirtualizationProviding`, `VMStorageProviding`, `DiskImageProviding`, `MacOSInstallProviding`, `IPSWProviding`

Services are split by concurrency requirements:

- **`@MainActor` services** (interact with `VZVirtualMachine`):
  - `VirtualizationService` — start, stop, pause, resume, save state, restore state
  - `MacOSInstallService` — loads restore image, creates platform files (aux storage, hardware model, machine identifier), runs `VZMacOSInstaller` with KVO progress tracking

- **`Sendable` struct services** (no mutable state, safe to call from anywhere):
  - `VMStorageService` — creates/deletes/lists VM bundle directories at `~/Library/Application Support/Kernova/VMs/`, handles cloning (deep copy with new UUID), and bundle migration for schema changes
  - `DiskImageService` — creates ASIF disk images by shelling out to `hdiutil`
  - `IPSWService` — fetches available macOS restore images from Apple's catalog and downloads IPSW files

- **`SystemSleepWatcher`** — `@MainActor` observer class that monitors `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`. Follows the same pattern as `VMDirectoryWatcher`: callback-driven, `nonisolated(unsafe)` for observer tokens, `start()`/`deinit` lifecycle. Owned by `VMLibraryViewModel`, which uses it to auto-pause running VMs before sleep and resume them on wake.

- **`ConfigurationBuilder`** — pure translation from `VMConfiguration` to `VZVirtualMachineConfiguration`. Handles three boot paths: `VZMacOSBootLoader` (macOS), `VZEFIBootLoader` (EFI/UEFI), and `VZLinuxBootLoader` (direct kernel boot). Configures CPU, memory, storage, network, display, keyboard, trackpad, and audio devices. Validates shared directory paths before VM launch (existence, is-directory, readable, writable for read-write shares).

All service implementations conform to protocols defined in `Services/Protocols/`. This enables full dependency injection — tests use mock implementations that track call counts and support error injection.

### ViewModels

**Files:** `VMLibraryViewModel.swift`, `VMLifecycleCoordinator.swift`, `VMCreationViewModel.swift`, `IPSWDownloadViewModel.swift`, `VMDirectoryWatcher.swift`

- **`VMLibraryViewModel`** is the central `@Observable` view model. It owns the array of `VMInstance`s and handles list-level operations: add, remove, rename, selection tracking. For lifecycle operations (start, stop, install), it delegates to `VMLifecycleCoordinator`.

- **`VMLifecycleCoordinator`** is an `@MainActor` coordinator that owns the lifecycle services (`VirtualizationService`, `MacOSInstallService`, `IPSWService`). It orchestrates multi-step operations like macOS installation (which involves IPSW download → platform file creation → VM configuration → installation). This separation keeps `VMLibraryViewModel` focused on list management. The coordinator enforces **per-VM operation serialization** — at most one lifecycle operation can be in flight for a given VM at any time; concurrent requests are rejected with `VMLifecycleCoordinator.LifecycleError.operationInProgress`. `stop` and `forceStop` bypass serialization entirely (clearing the active-operation token before calling the service) so users can always cancel hung operations.

- **`VMCreationViewModel`** drives the multi-step creation wizard. It tracks the current step, validates inputs at each stage, and produces a `VMConfiguration` + disk image on completion.

- **`IPSWDownloadViewModel`** manages IPSW download state (progress, cancellation) during macOS VM creation.

- **`VMDirectoryWatcher`** uses `DispatchSource.makeFileSystemObjectSource` to monitor the VMs directory for external changes (e.g., a user restoring a VM from Trash via Finder). When changes are detected, it triggers reconciliation in `VMLibraryViewModel` to sync the in-memory list with disk.

- **`SystemSleepWatcher`** (see Services section) is also owned by `VMLibraryViewModel`, triggering `pauseAllForSleep()` and `resumeAllAfterWake()` on system sleep/wake events. Auto-paused VMs are tracked in `sleepPausedInstanceIDs` so user-paused VMs are not accidentally resumed.

### Views

**Files:** 17 SwiftUI views across 4 subdirectories + root

Views observe `VMLibraryViewModel` and individual `VMInstance`s via the Observation framework. The view hierarchy:

```
ContentView
├── SidebarView → VMRowView (per VM)
└── VMDetailView
    ├── VMConsoleView → VMDisplayView (NSViewRepresentable for VZVirtualMachineView)
    ├── VMInfoView
    ├── VMSettingsView
    └── MacOSInstallProgressView
VMCreationWizardView (modal)
├── OSSelectionStep
├── IPSWSelectionStep / BootConfigStep
├── ResourceConfigStep
└── ReviewStep
SerialConsoleContentView → SerialTerminalView (in separate window)
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
    ├── creates → MainWindowController
    │                 └── NSSplitViewController
    │                       ├── NSHostingController(SidebarView)
    │                       └── NSHostingController(VMDetailView)
    │
    ├── manages → FullscreenWindowController (per VM)
    └── manages → SerialConsoleWindowController (per VM)

SwiftUI views ──observe──→ VMLibraryViewModel ──delegates──→ VMLifecycleCoordinator ──calls──→ Services
                           VMInstance (per VM)

SystemSleepWatcher ──sleep/wake──→ VMLibraryViewModel ──pause/resume──→ VMLifecycleCoordinator
```

### Utilities

**Files:** `DataFormatters.swift`, `FileManagerExtensions.swift`

- `DataFormatters` — human-readable formatting for bytes (e.g., "107.4 GB"), CPU counts, etc.
- `FileManagerExtensions` — convenience methods on `FileManager`

## Key Design Decisions

### 1. AppKit hosting SwiftUI

**What:** The app uses `NSSplitViewController` with `NSHostingController` children rather than a pure SwiftUI app.

**Why:** SwiftUI's `.toolbar` modifier doesn't propagate correctly through nested `NSHostingController`s. The app needs per-pane toolbars and precise window management (multiple window types per VM, fullscreen control) that SwiftUI's window APIs don't fully support. `NSToolbar` via `NSToolbarDelegate` gives full control.

**Alternatives:** Pure SwiftUI with `WindowGroup`/`Window` — would simplify code but loses toolbar control and multi-window management needed for VM display windows.

### 2. VM bundle as `.kernova` package directory

**What:** Each VM is a directory with a `.kernova` extension containing `config.json`, the disk image, auxiliary storage, save files, and serial logs.

**Why:** Treats each VM as an atomic unit in Finder. Users can move, copy, or delete VM bundles as single items. The directory structure is predictable via `VMBundleLayout`, and `config.json` makes the format human-inspectable.

**Alternatives:** SQLite database, single directory with UUID-named files, or Core Data. The bundle approach is simpler and more transparent.

### 3. ASIF disk images via hdiutil

**What:** Disk images use Apple Sparse Image Format, created by shelling out to `hdiutil`.

**Why:** ASIF provides near-native SSD performance with space efficiency — a 100 GB disk image starts at under 1 GB on disk and grows as the guest writes data. No third-party disk image library needed.

**Alternatives:** Raw disk images (simple but waste space), QCOW2 (not natively supported by Virtualization.framework), or `truncate` for sparse files (less reliable across file systems).

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

### 7. NSToolbar via delegate

**What:** The main window toolbar uses `NSToolbarDelegate` rather than SwiftUI's `.toolbar` modifier.

**Why:** SwiftUI toolbar items don't propagate through `NSHostingController` children. Since the main window is an `NSSplitViewController` with hosted SwiftUI panes, the toolbar must be configured at the AppKit level.

**Alternatives:** SwiftUI `.toolbar` — only works if the entire window is a single SwiftUI hierarchy, which it isn't.

## Dependencies

| Framework | Role |
|-----------|------|
| **Virtualization** | Core VM lifecycle — create, configure, start, stop, pause, resume VMs. Requires `com.apple.security.virtualization` entitlement. |
| **AppKit** | Window management (`NSWindowController`, `NSSplitViewController`), toolbar (`NSToolbar`), menus, app delegate. |
| **SwiftUI** | All views, hosted in `NSHostingController` children within AppKit window controllers. |
| **Observation** | `@Observable` macro for `VMInstance`, `VMLibraryViewModel`, `VMCreationViewModel`, `IPSWDownloadViewModel`. |
| **UniformTypeIdentifiers** | `UTType` declaration for `.kernova` VM bundles. |
| **os** | Unified logging via `os.Logger`. |

No external package dependencies. No Swift Package Manager, CocoaPods, or Carthage.

## Test Coverage

### Well Covered

| Component | Tests | Notes |
|-----------|-------|-------|
| `VMConfiguration` | 43 tests + clone suite | Encoding/decoding, defaults, validation, all fields |
| `VMLibraryViewModel` | 47 tests | Add/remove/rename VMs, selection, delegation to coordinator, sleep/wake |
| `VMCreationViewModel` | 44 tests | All wizard steps, validation, OS-specific paths |
| `VMLifecycleCoordinator` | Yes | Multi-step orchestration, error handling, service delegation, token-based operation serialization, stop/forceStop bypass, stale-token race condition coverage |
| `VMInstance` | Yes | Status transitions, configuration updates, bundle layout |
| `ConfigurationBuilder` | Yes | All three boot paths, device configuration |
| `VirtualizationService` | Yes | Start/stop/pause/resume via mock VZ objects |
| `VMStorageService` | Yes | CRUD operations, cloning, migration |
| `VMBundleLayout` | Yes | Path derivation from bundle root |
| `VMStatus` | Yes | Enum behavior and transitions |
| `VMBootMode` | Yes | Enum cases and properties |
| `VMGuestOS` | Yes | Enum cases and properties |
| `MacOSInstallState` | Yes | Phase tracking, progress calculation |
| `DataFormatters` | Yes | Byte formatting, CPU count formatting |

### Mocked but Not Directly Tested

These services interact with system processes, the network, or VZ installer internals. They are fully mocked in other tests but don't have their own test suites against real implementations:

- `DiskImageService` — shells out to `hdiutil`
- `IPSWService` — makes network requests to Apple
- `MacOSInstallService` — requires a real `VZVirtualMachine` and restore image

### Not Tested

- `VMDirectoryWatcher` — relies on `DispatchSource` file system monitoring
- `SystemSleepWatcher` — relies on `NSWorkspace` sleep/wake notifications (sleep/wake logic tested via `VMLibraryViewModel`)
- `IPSWDownloadViewModel` — wraps async download state
- `KernovaUTType` — static UTType declaration
- `FileManagerExtensions` — FileManager convenience methods
- `Logger` — thin os.Logger wrapper
- All window controllers (`MainWindowController`, `FullscreenWindowController`, `SerialConsoleWindowController`)
- `AppDelegate` — app lifecycle and window management
- All SwiftUI views

### Test Patterns

- **Framework:** Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest
- **Mocks:** 6 mock implementations conforming to service protocols, supporting call counting and error injection via `throwError` properties. Includes `SuspendingMockVirtualizationService` for testing operation serialization — suspends mid-operation to verify concurrent rejection and token-based race conditions. Relies on `@MainActor` cooperative scheduling (documented in the mock) and enforces single-suspension via `precondition`
- **Factories:** Shared helpers like `makeInstance()`, `makeViewModel()`, `makeCoordinator()` reduce setup duplication
- **Error paths:** Mocks support setting `throwError` to inject failures and verify error handling
