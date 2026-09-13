# Kernova

**Native virtual machines for Apple Silicon — macOS and Linux guests on Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization).**

![Platform](https://img.shields.io/badge/macOS%2026-Apple%20Silicon-000000?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![AppKit](https://img.shields.io/badge/UI-pure%20AppKit-0A84FF)
![App Sandbox](https://img.shields.io/badge/App%20Sandbox-on-34C759)
[![License](https://img.shields.io/badge/license-FSL--1.1--ALv2-blue)](LICENSE)

[Highlights](#highlights) · [Features](#features) · [Automation](#automation) · [Requirements](#requirements) · [Building](#building-kernova) · [Docs](#documentation) · [License](#license)

Kernova is a native Mac app for fast, disposable macOS and Linux VMs — no third-party hypervisor, no kernel extensions, no licensing. A source list of machines, one-click lifecycle, and deep host integration: shared clipboard, drag-and-drop, shared folders, port forwarding, audio, and an in-guest agent.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
    <img src="docs/images/hero-light.png" alt="Kernova main window: sidebar of VMs with a running macOS guest in the detail pane" width="900">
  </picture>
</p>

## Highlights

| | macOS guests | Linux guests |
|---|:---:|:---:|
| **Install** from IPSW, version catalog, URL, or local file · ISO catalog, URL, or local ISO | ✅ | ✅ |
| **Lifecycle** — start, stop, pause, resume, **suspend/restore**, force stop | ✅ | ✅ |
| **Snapshots** — live memory snapshots, instant copy-on-write, repeatable revert | ✅ | ✅ |
| **Ephemeral mode** — auto-revert to a baseline at every shutdown | ✅ | ✅ |
| **Clone** VMs and **import** `.kernova` bundles — instant APFS copies on the same volume | ✅ | ✅ |
| **Headless** operation from the status bar, **auto-start** at login | ✅ | ✅ |
| **Shared folders** over VirtioFS | ✅ | ✅ |
| **NAT** with **port forwarding** (TCP/UDP), **bridged**, **host-only** networking | ✅ | ✅ |
| **Hot-plug** removable media (ISOs, disk images) | ✅ | ✅ |
| **Audio** out, opt-in **microphone** passthrough | ✅ | ✅ |
| **Serial console** log and Unix-socket relay | ✅ | ✅ |
| **Clipboard sharing** — text, rich text, images, files, folders | ✅ | text only |
| **Drag-and-drop** files from Finder into the guest | ✅ | — |
| **Guest agent** with log forwarding to Console.app | ✅ | — |
| **HiDPI** display, **Recovery Mode** boot | ✅ | — |
| **CLI**, **Shortcuts**, **AppleScript**, **`kernova:` links** | ✅ | ✅ |

## Features

### Virtual machines

| | |
|---|---|
| **Creation wizard** | macOS from the latest IPSW, a version catalog, a URL, or a local file. Linux from a checksum-verified distribution catalog, an image URL, or a local ISO — EFI/UEFI or direct kernel boot. |
| **Lifecycle** | Start, stop, pause, resume, suspend, and restore. Force Stop for a hung VM; one-shot Start in Recovery Mode for macOS. |
| **Snapshots** | Named restore points with notes, taken running, suspended, or stopped — the first two capture memory too. Copy-on-write with the VM's own disks, so a snapshot is near-instant and adds little on disk. Revert is repeatable. |
| **Ephemeral mode** | Per-VM: every shutdown reverts to a chosen baseline snapshot. Suspend keeps the session; a sidebar badge marks the throwaway VM. |
| **Clone & import** | Clone with a fresh machine identity, or keep it (setting or ⌥-menu). Import `.kernova` bundles by double-click or drag-and-drop — an instant APFS clone on the same volume. |
| **Headless** | A status-bar item keeps VMs running after the last window closes and lists each one with its status. Quit save-suspends; sleep pauses, wake resumes. |
| **Auto-start** | Per-VM boot (or resume) whenever Kernova opens — with Open at Login, the Mac comes up with them running. |

> [!TIP]
> **Ephemeral mode** + a baseline snapshot gives you a clean test machine every boot — install once, break it freely, shut down, repeat.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/creation-wizard-dark.png">
    <img src="docs/images/creation-wizard-light.png" alt="The VM creation wizard's Review Configuration step, summarizing the name, operating system, boot mode, and resources before creating the VM" width="720">
  </picture>
</p>

### Virtual hardware

| | |
|---|---|
| **Storage** | **ASIF** sparse disks at near-native SSD speed, live on-disk vs. allocated size, extra disks with per-disk read-only and drag-to-reorder boot order. |
| **Removable media** | ISOs and disk images **hot-plugged** and ejected while the VM runs. |
| **Shared folders** | Host folders over **VirtioFS**, read-only or read-write. |
| **Display** | Resolution presets or custom size, **HiDPI**, size-to-fit at startup, live auto-resize. Inline, pop-out window, or **fullscreen** per VM; flip between the live display and a read-only settings form while running. |
| **Input** | Mac or USB keyboard/pointer, auto-picked by guest version. Per-VM choice of when **system hot keys** reach the guest: never, in full screen, or always — live-switchable. |
| **Audio** | Guest audio to the host, on by default. **Microphone** passthrough opt-in per VM, off by default. |
| **Network** | **Shared (NAT)** with TCP/UDP **port forwarding** · **Bridged** to a chosen interface or Automatic · **Host Only** · None. Live **IP address** readout; persistent, editable **MAC address** with one-click regeneration and a duplicate warning. |
| **Serial** | Size-capped `serial.log` in the bundle, plus an opt-in **AF_UNIX socket** relay for `socat` / `nc -U`, hot-toggleable. |

> [!NOTE]
> **Bridged** and **Host Only** need Apple's restricted `com.apple.vm.networking` entitlement. A build without it hides those modes and everything else works unchanged.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/vm-settings-dark.png">
    <img src="docs/images/vm-settings-light.png" alt="VM settings form showing the General, Resources, Storage Disks, Removable Media, Shared Directories, Network, and Audio sections" width="720">
  </picture>
</p>

### Guest integration

| | |
|---|---|
| **Guest agent** (macOS) | A lightweight in-guest helper installed from an attachable disk. Talks to the host over **vsock**; its own status-bar menu shows the connection, what's shared, and when an update is available. |
| **Clipboard sharing** | Bidirectional text, rich text, images, files, and folders. Copy is instant; only a **paste** moves bytes — up to a ceiling (2 GB default) with integrity checks and live progress in a clipboard window. Opt-in **Automatic Passthrough** syncs continuously. Passwords show a locked placeholder; transient content is skipped. Linux: text, via **spice-vdagent**. |
| **Drag-and-drop** (macOS) | Drop files from Finder onto the display; they land in the guest's Downloads and are revealed, never overwriting, with live progress. |
| **Log forwarding** (macOS) | Opt-in, live-toggleable: the guest's `os.Logger` records appear in **Console.app** under `app.kernova.guest`. |

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/clipboard-dark.png">
    <img src="docs/images/clipboard-light.png" alt="The clipboard window showing rich text with an embedded image shared between host and guest" width="720">
  </picture>
</p>

### The app

Pure AppKit in the **Liquid Glass** design language — a source-list sidebar with drag reordering and inline rename, a customizable toolbar, and a delete sheet that offers to trash a VM's external attachments with it.

| Settings pane (⌘,) | Holds |
|---|---|
| **General** | Open at Login · keep running in the status bar |
| **Clipboard** | Maximum paste size |
| **Reminders** | Status-bar quit reminder · guest-agent install nudge, app-wide and per VM |
| **Advanced** | Always show ⌥-gated commands · block duplicate machine IDs from booting · new machine ID for clones · install the CLI and shell completions |

## Automation

Four surfaces, one library, the same verbs.

| Surface | What it offers |
|---|---|
| **Shortcuts & Spotlight** | App Intents for the lifecycle (start, stop, pause, resume, suspend, restart, open, reveal), the library (search, import, clone, rename, delete), snapshots (take, find, revert, rename, notes, delete), and reading state or IP — each VM a typed entity you pick by name. |
| **AppleScript** | A scripting dictionary with the lifecycle verbs and every VM property, for Script Editor and Automator. |
| **Kernova CLI** | Bundled at `Contents/Helpers/kernova`; **Settings → Advanced → Install…** links it into a folder on your `PATH`. Lifecycle, settings read/write, snapshots, shared folders, port forwarding, USB accessories, `wait`, and `--format json` on every verb. Shell completions for zsh, bash, and fish. |
| **URL scheme** | Clickable links from a browser, a note, or a script. `kernova://open/<name>` brings a running VM's display forward and refuses when it has none; `kernova://reveal/<name>` never refuses — the display when there is one, the VM's library row otherwise. |

```bash
kernova start Alpha
kernova wait Alpha --until agent
kernova ip Alpha --wait
kernova snapshot take Alpha --name "before upgrade"
kernova share add Alpha ~/Projects --read-only
kernova forward add Alpha 2222:22
kernova get Alpha memory --format json
```

A verb launches Kernova hidden when it isn't running; `--no-launch` refuses instead. `kernova --help` lists every verb, flag, and the exit codes a script branches on.

<details>
<summary><b>AppleScript idioms</b> the dictionary alone doesn't show</summary>

```applescript
tell application "Kernova"
    -- A name matches without regard to case; a `whose` test filters the library.
    get name of every virtual machine whose state is running

    -- `IP address` is `missing value` until the guest has one.
    start virtual machine "Alpha"
    repeat until IP address of virtual machine "Alpha" is not missing value
        delay 1
    end repeat

    -- A stop that discards guest state refuses without `with confirmation`.
    -- AppleScript gives up on a reply after two minutes unless told otherwise.
    with timeout of 600 seconds
        stop virtual machine "Alpha" by force with confirmation
    end timeout
end tell
```

**File → Open Dictionary…** in Script Editor lists every verb, parameter, and property.

</details>

## Requirements

| | |
|---|---|
| **Host** | macOS 26 (Tahoe) or later · Apple Silicon |
| **macOS guests** | macOS 12.0.1 (Monterey) and later, including the guest agent |
| **Linux guests** | ARM64 — Ubuntu, Debian, Fedora, and Kali from the catalog, or any image of your own |

## Building Kernova

Kernova builds from source with **Xcode 26** and **Swift 6**. After cloning:

```bash
make setup   # one-time per clone; idempotent, rerun any time
```

| `make setup` step | What it does |
|---|---|
| **Git hooks** | Activates the checked-in `.githooks/` — a pre-push `make lint` matching the required check on `main` (`git push --no-verify` bypasses once) and a post-checkout hook that readies new worktrees ([docs/BUILD.md](docs/BUILD.md)). |
| **Homebrew tools** | `shellcheck`, `gh`, `protoc`, `xcode-build-server` — skipped if present or if [Homebrew](https://brew.sh) is absent; none is needed to build or test. |
| **`buildServer.json`** | Gives editors and language servers the project's real compiler flags; build once for them to resolve. |
| **Periphery** | The pinned release `make dead-code` scans with. |
| **`make doctor`** | Checks toolchain, signing, and hooks against what Kernova needs. |

Then open `Kernova.xcodeproj`, pick the `Kernova` scheme, and run (⌘R). `make` alone lists every build, test, format, and lint target.

> [!IMPORTANT]
> **Debug needs no Apple account** — it signs ad-hoc, so a fresh clone builds and runs as-is. With a development certificate, point Debug at it via a gitignored `Config/Local.xcconfig` (from `Config/Local.xcconfig.example`) so privacy grants survive rebuilds ([docs/BUILD.md](docs/BUILD.md#signing-identity)). **Release** needs a paid membership and a distribution identity ([docs/RELEASING.md](docs/RELEASING.md)).

The `com.apple.security.virtualization` entitlement is already in the project configuration.

### Testing

```bash
make test
```

Runs every test target via the test plan — [Swift Testing](https://developer.apple.com/documentation/testing/) against protocol-based mocks ([docs/TESTING.md](docs/TESTING.md)).

## Documentation

| Read | For |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Component map, data flow, design decisions |
| [DESIGN.md](docs/DESIGN.md) | Design philosophy and UI guidelines |
| [CLIPBOARD.md](docs/CLIPBOARD.md) | The clipboard subsystem's principles |
| [NETWORKING.md](docs/NETWORKING.md) | Networking principles |
| [VERSION-FLOORS.md](docs/VERSION-FLOORS.md) | Which guest versions support what |
| [docs/README.md](docs/README.md) | The full index |

## Contributing and security

Bug reports and feedback are welcome as [issues](https://github.com/nicholas-lonsinger/kernova/issues). Outside code contributions aren't being accepted yet — [CONTRIBUTING.md](CONTRIBUTING.md) explains why. Report vulnerabilities privately through [GitHub's advisory form](https://github.com/nicholas-lonsinger/kernova/security/advisories/new); [SECURITY.md](SECURITY.md) describes what's in scope.

## License

Kernova is **source-available** under the [Functional Source License (FSL-1.1-ALv2)](LICENSE): use, modify, and redistribute it for any purpose **except** a competing commercial product or service. Internal use, non-commercial education, and non-commercial research are explicitly permitted. Each release converts to Apache 2.0 two years after publication.
