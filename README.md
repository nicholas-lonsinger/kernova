# Kernova

**Native virtual machines for Apple Silicon — macOS and Linux guests, built on Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization).**

![License: FSL-1.1-ALv2](https://img.shields.io/badge/license-FSL--1.1--ALv2-blue)
![Platform: macOS 26 · Apple Silicon](https://img.shields.io/badge/platform-macOS%2026%20%C2%B7%20Apple%20Silicon-lightgrey)

Kernova is a pure-AppKit Mac app for creating and running virtual machines directly on Apple Silicon — no third-party hypervisor, no kernel extensions, no licensing. It's for developers, QA engineers, and power users who want fast, disposable macOS and Linux VMs that feel like part of the Mac: a real source list of machines, one-click lifecycle, and deep host integration — shared clipboard, files, audio, and an in-guest agent — all inside the App Sandbox.

Requires macOS 26 (Tahoe) or later on Apple Silicon.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
    <img src="docs/images/hero-light.png" alt="Kernova main window: sidebar of VMs with a running guest in the detail pane" width="900">
  </picture>
</p>

## Features

### Virtual machines

- **macOS and Linux guests** — a step-by-step creation wizard, including IPSW download for macOS; EFI/UEFI or direct kernel boot for Linux
- **Full lifecycle** — start, stop, pause, resume, suspend, and restore, plus Force Stop for a hung VM and a one-shot Start in Recovery Mode for macOS guests
- **Cloning and import** — clone a VM with freshly regenerated identifiers; import `.kernova` bundles by double-click or drag-and-drop, which is also how you bring existing VMs into the sandboxed library (on the same volume it's an APFS clone: near-instant, no double disk usage)
- **Keeps running in the background** — a resident menu-bar app with an opt-in Open at Login toggle, so closing the window leaves VMs running headless. Quitting save-suspends them; system sleep auto-pauses and wake resumes

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/creation-wizard-dark.png">
    <img src="docs/images/creation-wizard-light.png" alt="The VM creation wizard selecting a guest operating system" width="720">
  </picture>
</p>

### Virtual hardware

- **Storage** — ASIF sparse disks for near-native SSD performance, with live on-disk-vs-allocated capacity, extra disks with per-disk read-only and drag-to-reorder boot order, and hot-plug removable media (ISOs, disk images) attachable and ejectable while the VM runs
- **Shared directories** — host folders exposed over VirtioFS, read-only or read-write
- **Display** — configurable resolution and DPI; per-VM choice of inline, pop-out window, or fullscreen, and a toggle between the live display and a read-only settings form while the VM runs
- **Audio** — guest audio routed to the host, on by default; host microphone passthrough opt-in per VM, off by default for privacy
- **Network** — persistent, stable MAC addresses
- **Serial** — output persisted to `serial.log` in the bundle, plus an opt-in AF_UNIX socket relay for external tools (`socat`, `nc -U`), hot-toggleable while running

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/vm-settings-dark.png">
    <img src="docs/images/vm-settings-light.png" alt="VM settings form showing the Storage Disks, Removable Media, and Audio sections" width="720">
  </picture>
</p>

### Guest integration

- **Guest agent (macOS guests)** — a lightweight in-guest menu-bar helper, installed from an attachable installer disk, reporting status and version to the host over vsock
- **Clipboard sync** — bidirectional host↔guest text, rich text, images, and multiple files or entire folders, with no size cap, integrity verification, and live transfer progress in a dedicated clipboard window. Concealed and password content shows a locked placeholder; transient snapshots aren't synced. macOS guests sync over the vsock agent, Linux guests sync text only via spice-vdagent
- **Lazy file transfer** — File Providers on both sides materialize pasted files on demand rather than up front, in either direction
- **Log forwarding (macOS guests)** — opt-in per VM and live-toggleable; the guest's `os.Logger` records surface on the host in Console.app under the `app.kernova.guest` subsystem

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/clipboard-dark.png">
    <img src="docs/images/clipboard-light.png" alt="The clipboard window showing a file transfer between host and guest" width="720">
  </picture>
</p>

### The app itself

Pure AppKit in the Liquid Glass design language: a source-list sidebar with drag reordering and inline rename, a customizable toolbar, a Settings window (⌘,), and a deletion sheet that offers to trash a VM's external attachments alongside it.

## Development setup

Everything below is for building and working on Kernova itself. You'll need Xcode 26 and Swift 6 on top of the requirements above.

After cloning:

```bash
make install-hooks   # one-time per clone
make bootstrap       # derives your signing team
```

`install-hooks` points the repo at the checked-in `.githooks/`, which Git does not activate on its own: a pre-push `make lint` matching the required `lint` check on `main` (bypass a single push with `git push --no-verify`), and a post-checkout hook that makes a new git worktree build in Xcode with no manual setup.

`bootstrap` derives your own signing team from your Apple Development (or Developer ID) certificate into a gitignored `Config/Local.xcconfig`, so a Debug build signs as *you* rather than a hardcoded team. `make build` and `make test` run it for you; Xcode's ⌘R does not, so run it by hand before building a fresh clone from the IDE. The hook and bootstrap machinery is documented in [docs/BUILD.md](docs/BUILD.md).

Then open `Kernova.xcodeproj`, select the `Kernova` scheme, and build and run (⌘R). The app requires the `com.apple.security.virtualization` entitlement, already in the project configuration.

`make doctor` checks that your toolchain, signing team, and hooks match what Kernova needs. `make` with no arguments lists every build, test, format, and lint target.

**Debug signs with *any* team** — no Apple Developer Program membership or developer-portal setup needed, just `make bootstrap`. **Release** additionally requires a paid membership and a distribution identity (Developer ID, or Apple Distribution for the Mac App Store) and fails to sign without one; it matters only when cutting a distributable build. The per-configuration app-group and signing story is in [docs/SANDBOX.md](docs/SANDBOX.md).

## Testing

```bash
make test
```

Runs all three test targets via the test plan. Tests use [Swift Testing](https://developer.apple.com/documentation/testing/) against protocol-based mocks; the conventions are in [docs/TESTING.md](docs/TESTING.md).

## Architecture

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the component map, data flow, and design decisions; [docs/README.md](docs/README.md) indexes the rest, including [docs/SPEC.md](docs/SPEC.md) for design philosophy and UI guidelines and [docs/CLIPBOARD.md](docs/CLIPBOARD.md) for the clipboard subsystem.

## License

Kernova is **source-available** under the [Functional Source License (FSL-1.1-ALv2)](LICENSE): you're free to use, modify, and redistribute it for any purpose **except** offering a competing commercial product or service. Internal use, non-commercial education, and non-commercial research are explicitly permitted. Each release converts to Apache 2.0 two years after its publication. See [LICENSE](LICENSE) for the full terms.
