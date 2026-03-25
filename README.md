# Kernova

A macOS GUI application for creating and managing virtual machines using Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization).

## Features

### Virtual Machines

- **macOS & Linux guests** — Run macOS virtual machines on Apple Silicon and Linux VMs with EFI or direct kernel boot
- **Full VM lifecycle** — Start, stop, pause, resume, suspend, and restore
- **VM cloning** — Clone existing VMs with automatic naming
- **Bundle import** — Import VM bundles (`.kernova`) via double-click or drag-and-drop
- **Graceful shutdown** — Suspends running VMs automatically on app termination

### Guest Configuration

- **Creation wizard** — Step-by-step VM creation with IPSW download for macOS guests
- **Linux boot modes** — EFI/UEFI boot or direct kernel boot with kernel, initrd, and command-line args
- **ISO attachment** — Mount disc images as USB drives for installation media, with boot priority support
- **Shared directories** — Host-to-guest directory sharing via VirtioFS (read-only or read-write)
- **Display settings** — Configurable resolution and DPI (width, height, PPI)
- **Network** — MAC address management with persistent, stable addresses
- **ASIF disk images** — Apple Sparse Image Format for near-native SSD performance with space-efficient storage

### Display and Console

- **Native UI** — AppKit app with SwiftUI views, Liquid Glass design language
- **Fullscreen mode** — Dedicated fullscreen window per VM
- **Serial console** — Terminal window for serial port access

### Management

- **VM renaming** — Inline rename or via menu
- **Sleep integration** — Auto-pauses running VMs on system sleep, resumes on wake
- **Directory watching** — Monitors the VMs directory for external filesystem changes
- **Config migration** — Automatic schema migration for configuration compatibility

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon (required for macOS guests)
- Xcode 26 or later
- Swift 6

## Building

1. Open `Kernova.xcodeproj` in Xcode 26
2. Select the `Kernova` scheme
3. Build and run (Cmd+R)

The app requires the `com.apple.security.virtualization` entitlement, which is included in the project configuration.

## Testing

The project has comprehensive test coverage using [Swift Testing](https://developer.apple.com/documentation/testing/) (`@Test`, `#expect`). All services use protocol-based dependency injection with mock implementations for full testability.

```bash
xcodebuild -project Kernova.xcodeproj -scheme Kernova -destination 'platform=macOS' test
```

See the test coverage section in [ARCHITECTURE.md](ARCHITECTURE.md) for details.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed component descriptions, data flow diagrams, and design decisions.

```
Kernova/
├── App/          # AppDelegate, MainWindowController
├── Models/       # VMConfiguration, VMInstance, enums
├── Services/     # VM lifecycle, storage, disk images, IPSW, installation
├── Views/        # SwiftUI views (sidebar, detail, console, creation wizard)
├── ViewModels/   # Observable view models
└── Utilities/    # Formatters, extensions
```

### Key Components

- **VMConfiguration** — Codable model persisted as `config.json` in each VM bundle
- **VMInstance** — Runtime wrapper combining config, VZVirtualMachine, and status
- **ConfigurationBuilder** — Translates VMConfiguration into VZVirtualMachineConfiguration
- **VirtualizationService** — VM lifecycle management (start/stop/pause/save/restore)
- **VMStorageService** — VM bundle CRUD at `~/Library/Application Support/Kernova/VMs/`
- **VMLifecycleCoordinator** — Orchestrates multi-step VM operations with per-VM serialization
- **VMDirectoryWatcher** — Monitors the VMs directory for external filesystem changes
- **SystemSleepWatcher** — Pauses running VMs on system sleep and resumes on wake

### VM Bundle Structure

Each VM is stored as a directory under `~/Library/Application Support/Kernova/VMs/<UUID>/`:

```
<UUID>/
  config.json           # Serialized VMConfiguration
  Disk.asif             # ASIF sparse disk image
  AuxiliaryStorage      # macOS auxiliary storage
  HardwareModel         # VZMacHardwareModel data
  MachineIdentifier     # VZMacMachineIdentifier data
  SaveFile.vzvmsave     # Saved VM state (suspend/resume)
```

## License

MIT License. See [LICENSE](LICENSE) for details.
