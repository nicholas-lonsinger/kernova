# Kernova

A macOS GUI application for creating and managing virtual machines using Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization).

## Features

### Virtual Machines

- **macOS & Linux guests** — Run macOS virtual machines and Linux VMs with EFI or direct kernel boot
- **Full VM lifecycle** — Start, stop, pause, resume, suspend, and restore
- **VM cloning** — Clone existing VMs with automatic naming
- **Bundle import** — Import VM bundles (`.kernova`) via double-click or drag-and-drop
- **Recovery mode** — Boot macOS guests into Recovery
- **Headless operation** — The app runs as a launch-at-login background agent, so quitting the window keeps VMs running headless
- **Graceful shutdown** — Save-suspends running VMs automatically when the background agent itself terminates (status-item Quit, logout, or shutdown)

### Guest Configuration

- **Creation wizard** — Step-by-step VM creation with IPSW download for macOS guests
- **Linux boot modes** — EFI/UEFI boot or direct kernel boot with kernel, initrd, and command-line args
- **ISO attachment** — Mount disk images as USB drives for installation media, with boot priority support
- **Shared directories** — Host-to-guest directory sharing via VirtioFS (read-only or read-write)
- **Display settings** — Configurable resolution and DPI (width, height, PPI)
- **Network** — MAC address management with persistent, stable addresses
- **Audio** — Per-VM audio output and microphone passthrough toggles
- **ASIF disk images** — Apple Sparse Image Format for near-native SSD performance with space-efficient storage

### Display and Console

- **Native UI** — Pure-AppKit app, Liquid Glass design language
- **Fullscreen mode** — Dedicated fullscreen window per VM
- **Serial console** — Terminal window for serial port access

### Clipboard & File Sharing

- **Clipboard sync** — Host↔guest clipboard sharing for text, rich text, images, files, and folders — chunk-streamed with no size cap and live transfer progress on macOS guests (via the vsock guest agent); Linux guests sync clipboard text only (spice-vdagent)
- **Guest agent** — In-guest menu-bar agent for macOS guests (vsock transport), installed from an attachable installer disk
- **Copy to Mac** — Lazy guest→host file transfer backed by a host File Provider, so pasted files materialize on demand
- **Large-file paste** — A guest File Provider transport materializes large host files inside the guest on demand

### Management

- **VM renaming** — Inline rename or via menu
- **Sleep integration** — Auto-pauses running VMs on system sleep, resumes on wake
- **Directory watching** — Monitors the VMs directory for external filesystem changes
- **Quick Look** — Preview `.kernova` bundles from Finder with the bundled Quick Look extension

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon
- Xcode 26 or later
- Swift 6

## Development setup

After cloning, run:

```bash
make install-hooks
make bootstrap
```

`install-hooks` points the repo at the checked-in `.githooks/` directory. It's a one-time setup per clone (Git does not auto-activate checked-in hooks) and enables two hooks: a pre-push hook that runs `make lint` locally, matching the required `lint` check enforced on `main` (bypass an individual push with `git push --no-verify`), and a post-checkout hook that sets up new git worktrees — it copies the gitignored local files listed in [`.worktreeinclude`](.worktreeinclude) from the main checkout (the same list Claude Code and other worktree tools consume when *they* create a worktree, so `git worktree add` honors it too), then re-runs `bootstrap` (below) if `Config/Local.xcconfig` is still missing — so a new git worktree builds in Xcode immediately with no manual step.

`bootstrap` derives your own signing team from your Apple Development (or Developer ID) certificate into a gitignored `Config/Local.xcconfig`, so a Debug build signs as *you* rather than a hardcoded team — see [Signing: Debug vs Release](#signing-debug-vs-release) below. `make build` and `make test` run it automatically, and the post-checkout hook covers additional git worktrees (each needs its own `Config/Local.xcconfig`, since gitignored files aren't shared between worktrees; the hook copies the main checkout's file, falling back to fresh derivation), so this is only a manual step if you're building a fresh clone straight from Xcode without ever running a `make` target first.

Run `make doctor` to confirm your local toolchain (macOS, Xcode, Swift, swift-format), signing team, and git hooks match what Kernova needs before building.

Run `make` with no arguments to see all build, test, format, and lint targets.

## Building

1. Open `Kernova.xcodeproj` in Xcode 26
2. Select the `Kernova` scheme
3. Build and run (Cmd+R)

The app requires the `com.apple.security.virtualization` entitlement, which is included in the project configuration. If you haven't run `make bootstrap` yet (see above), do that first — Xcode's own ⌘R doesn't run it for you.

### Signing: Debug vs Release

Kernova signs differently per build configuration, driven by the `KERNOVA_APP_GROUP` build setting that scopes the clipboard File Provider's shared container:

- **Debug** uses a Team-ID-prefixed app group (`$(DEVELOPMENT_TEAM).app.kernova`). macOS grants a Team-ID-prefixed group silent container access with **no provisioning profile**, so a Debug build (⌘R, `make build`, `make test`) works with *any* signing team. `DEVELOPMENT_TEAM` is not hardcoded: `make bootstrap` ([`Tools/bootstrap-team.sh`](Tools/bootstrap-team.sh)) derives it from your own signing certificate into a gitignored `Config/Local.xcconfig`, included by the tracked `Config/Base.xcconfig` ([#476](https://github.com/nicholas-lonsinger/kernova/issues/476)). No Apple Developer Program membership or developer-portal setup is needed to build and run, and the guest agent never shows the "access data from other apps" consent prompt in a VM.
- **Release** uses the canonical `group.app.kernova`. That form is **not** silently authorized: it requires the app group registered on the Apple Developer portal plus an embedded provisioning profile, which in turn requires a paid **Apple Developer Program** membership and a distribution identity — **Developer ID** for direct distribution, or Apple Distribution for the Mac App Store. A Release build fails to sign without them.

Day-to-day development only needs Debug. The Release path matters when cutting a distributable build; see the *Mac App Store Readiness* section of [CLAUDE.md](CLAUDE.md) for the full rationale.

## Testing

The project has comprehensive test coverage using [Swift Testing](https://developer.apple.com/documentation/testing/) (`@Test`, `#expect`). All services use protocol-based dependency injection with mock implementations for full testability.

```bash
make test
```

This runs all three test targets via the test plan; it wraps the canonical `xcodebuild` invocation documented in [CLAUDE.md](CLAUDE.md). See the test coverage section in [ARCHITECTURE.md](ARCHITECTURE.md) for details.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed component descriptions, data flow diagrams, and design decisions.

```
Kernova/
├── App/          # AppDelegate, MainWindowController
├── Models/       # VMConfiguration, VMInstance, enums
├── Services/     # VM lifecycle, storage, disk images, IPSW, installation
├── Views/        # AppKit view controllers (sidebar, detail, console, creation wizard)
├── ViewModels/   # Observable view models
└── Utilities/    # Formatters, extensions
```

Alongside the app target, the repo contains the in-guest menu-bar agent (`KernovaMacOSAgent/`), the shared SwiftPM package (`KernovaKit/`), the Quick Look extension (`KernovaQuickLook/`), the guest and host clipboard File Provider extensions (`KernovaMacOSAgentFileProvider/`, `KernovaFileProvider/`), and the relaunch helper (`KernovaRelaunchHelper/`) — see [ARCHITECTURE.md](ARCHITECTURE.md) for the full map.

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

Kernova is **source-available** under the [Functional Source License (FSL-1.1-ALv2)](LICENSE): you're free to use, modify, and redistribute it for any purpose **except** offering a competing commercial product or service. Internal use, non-commercial education, and non-commercial research are explicitly permitted. Each release converts to Apache 2.0 two years after its publication. See [LICENSE](LICENSE) for the full terms.
