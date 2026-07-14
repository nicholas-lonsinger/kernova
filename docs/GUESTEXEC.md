# GUESTEXEC.md

Guiding principles for host→guest command execution ("guest exec") in Kernova.

> This document is **authoritative** for the guest-exec subsystem. Consult it before
> designing, extending, or refactoring any guest-exec code — and before picking up any
> guest-exec issue. Where it conflicts with intuition or with an existing implementation,
> this document wins and the implementation is the thing to change. Structural facts
> (types, data flow, test coverage) live in [ARCHITECTURE.md](ARCHITECTURE.md); product and
> UI philosophy live in [SPEC.md](SPEC.md). This file is the *why* and the *rules*.
> It was written before the first implementation, deliberately: the security posture here
> is a design input, not a retrofit.

## Scope

- **In scope:** host-initiated execution of commands inside a running **macOS guest**, over
  the existing vsock transport, carried out by `KernovaGuestAgent` in the guest user's login
  session. The command, its arguments, and its working context flow host→guest; exit status
  and captured output flow back as data.
- **Primary purpose today:** streamlining development and debugging of Kernova itself —
  poking at guest state, tailing guest-side logs, exercising agent behavior without opening
  Screen Sharing or configuring SSH. Future local automation features may build on the same
  channel, governed by the same principles.
- **Out of scope:** Linux guests (no Kernova agent runs there), and everything listed under
  [Non-goals](#non-goals) — most importantly guest→host execution and cross-machine remote
  control, which are not deferred features but different threat models.

---

## Threat model and north star

**Guest exec is a convenience conduit for power the host already has — it must never become
a new power.** The host owns the guest's disk image, memory, and boot chain; anything that
controls Kernova's process could already tamper with the guest offline. Command execution
adds no theoretical capability, and the isolation boundary that matters — *the guest cannot
touch the host* — is untouched: output returning to the host is data, nothing more.

What the feature *can* degrade is practical security, along three axes:

1. **Reachability** — how easily something running on the host (other than the user driving
   Kernova's UI) can reach into a running guest.
2. **Visibility** — whether the guest-side user knows a remote-execution channel exists and
   is active.
3. **Correctness** — whether the channel itself introduces bugs (injection, unbounded
   output) that turn a debugging tool into a foothold.

Every principle below exists to hold one of those three axes flat.

---

## Principles

### 1. Local-only and process-confined

**The only way to invoke guest exec is Kernova's own UI, in Kernova's own process.** The
transport is vsock through `VZVirtioSocketDevice`, which is reachable only from within the
process that owns the `VZVirtualMachine` — that confinement is the security model, and it
must never be bridged.

- **No external invocation surface, ever:** no AppleScript/Apple events, no URL scheme, no
  CLI companion, no XPC service, no file-drop command queue, and no network listener that
  proxies onto the exec channel. The moment one exists, any malware on the host that could
  not touch a VM can run commands inside every guest with the toggle on.
- This is what makes the feature's marginal risk acceptable: an attacker who can drive the
  exec channel already fully controls Kernova, which is already game over for its guests.
- If a future feature genuinely needs programmatic invocation, that is an
  [escalation](#8-escalations-are-new-decisions-not-increments) requiring its own design —
  authentication, authorization, and audit — not an entitlement to widen this channel.

### 2. Off by default; opt-in is per-VM and enforced in the guest

**Guest exec ships disabled and is enabled per VM, and the *guest agent* is what enforces
the state.** Following the established `PolicyUpdate` pattern: the host sends the policy
snapshot, and a disabled guest agent genuinely stops the service — it does not accept exec
frames for the host to politely not send. Host-side filtering is courtesy, not enforcement.

- The toggle is a deliberate per-VM setting, never a global default, never enabled silently
  by another feature.
- A guest agent that has never received a policy enabling exec must behave identically to an
  agent built without the feature.

### 3. The guest user can see it and stop it

**Silent remote execution is spyware-shaped, even against your own VM.** The guest side must
make the channel legible:

- The agent's menu-bar UI shows when command execution is enabled, distinct from the
  clipboard/log capabilities.
- The guest user can disable it or quit the agent, and either takes effect immediately.
- There is no mode in which commands execute in a guest whose agent UI claims the capability
  is off.

### 4. Guest-user privileges — never root

**Commands run as the logged-in guest user, because that is who the agent is.** The agent is
a login item in the guest user's session; exec inherits exactly that identity and nothing
more.

- No privileged helper, no setuid tool, no `sudo` affordance, no "run as root" mode. Root
  execution is where the risk profile actually changes, and it is a
  [non-goal](#non-goals).
- **TCC is part of the privilege boundary.** Anything a command touches under the guest's
  protected locations (Desktop, Documents, etc.) runs with the *agent's* TCC identity.
  Granting the agent a TCC permission to unblock one debug command permanently widens what
  every future host-sent command can reach — prefer commands that don't need the grant, and
  treat any agent TCC grant as a deliberate, documented decision.

### 5. Argv is the protocol; a shell is an explicit choice

**The wire format carries an argument vector — executable plus arguments — with explicit
working directory, environment, and timeout.** The guest spawns the process from argv
directly (`Process` with `executableURL` + `arguments`), so there is no string for metadata
to leak into and no quoting to get wrong.

- Interpolating UI-derived values (a VM name, a path, user input) into a shell string is the
  classic injection defect; the argv-first protocol makes it structurally impossible on the
  default path.
- "Run this line through the user's shell" is a legitimate debugging convenience, but it is
  a **separate, explicit mode** — a distinct field or message the host sets deliberately —
  never the default the convenient API happens to produce.

### 6. Command content is guest-visible — never a secret channel

**Assume the guest can read every command the host sends.** A malicious guest process could
bind the exec vsock port before the agent and impersonate it; the consequence is bounded (it
already runs code in the guest) precisely *because* commands must never carry anything the
guest shouldn't see.

- Never embed host-side secrets — tokens, host paths that reveal sensitive context,
  credentials — in command lines or environment values.
- The guest is untrusted (the same stance as the clipboard subsystem,
  [CLIPBOARD.md §10](CLIPBOARD.md)): exec replies, like all guest traffic, are handled as
  untrusted input.

### 7. Output is bounded, opaque, and potentially sensitive

**Stdout/stderr stream back as opaque bytes with caps the host chooses.**

- **Bounded:** every execution carries a timeout and an output ceiling, ended by an in-band
  abort (the message-not-disconnect convention the clipboard stream protocol established) —
  a runaway `yes(1)` must not wedge the channel or balloon host memory.
- **Opaque:** output is for display and logs. The host never parses guest output to make a
  security- or state-relevant decision (the guest is untrusted; see §6).
- **Sensitive:** output can contain guest secrets. It stays at non-persisted log levels
  (`.debug`/`.info`); lifecycle events (`.notice`) record that a command ran and its exit
  status, never the command text or output. Persistent host-side command history is a
  feature decision to make explicitly (with the privacy trade-off written down), not a side
  effect of logging.

### 8. Escalations are new decisions, not increments

**Each of the following changes the threat model and requires revisiting this document
first — none may arrive as an incremental patch to the existing channel:**

- Programmatic/scriptable invocation from outside Kernova's UI (§1).
- Elevated (root) execution in the guest (§4).
- Interactive sessions (a PTY / streaming stdin): plausible future work, but it converts
  "run a command" into "hold a shell," with its own lifecycle, signal, and UI questions.
- Any network reachability, including "just on localhost."

If a proposal needs one of these, the proposal's first deliverable is an update to this
file that carves out the new boundary — then the code.

---

## Non-goals

These are not deferred features; they are boundaries. Code and protocol design must not
speculatively accommodate them (see the project rule against building for a future maybe):

- **Guest→host execution. Never.** The entire security story of a VM app is that the guest
  cannot touch the host; no debugging convenience is worth a channel pointed the other way.
- **Cross-machine remote control.** This subsystem's security derives from being local and
  process-confined (§1). A networked "remote control" product is a categorically different
  threat model — authentication, authorization, transport encryption, audit — and must be
  designed as its own system, not a proxy wrapped around this channel.
- **Root execution in the guest** (§4).
- **A guest-side agent-less mode.** Exec exists only where the Kernova guest agent runs,
  with its UI and policy enforcement; no fallback that injects commands some other way.

---

## Precedent

Host→guest exec is a standard capability of mature VM managers, which grounds both the
feature's legitimacy and its shape:

- **QEMU guest agent** — `guest-exec` / `guest-exec-status` over a virtio-serial channel:
  argv-based, capture-and-poll output, agent-enforced availability.
- **VirtualBox** — `VBoxManage guestcontrol run` via Guest Additions, with explicit guest
  credentials.
- **VMware Tools** — guest operations API (`StartProgramInGuest`), also credentialed.
- **Parallels** — `prlctl exec`.
- **Tart / Lume** (the closest Virtualization.framework peers) — no exec channel; they rely
  on SSH into the guest.

The SSH route is the zero-new-surface alternative and remains available to users. The
integrated channel earns its place by needing no guest network or credential setup, working
uniformly across VMs, and being governed by the agent's policy/visibility machinery — while
the QEMU-style agent-mediated, argv-based, poll/stream-output design is the pattern Kernova
follows.

---

## Engineering practices

Non-negotiable mechanics for how guest-exec changes ship — these mirror the conventions the
clipboard and log services established:

- **Wire conventions.** The exec service claims its own payload-number range in the
  `Frame` oneof and its own vsock port beside `control`/`clipboard`/`log`; capabilities are
  advertised in the `Hello` exchange; enablement flows through `PolicyUpdate` (§2). No
  legacy shims — a behavior change that requires a guest reinstall bumps the guest agent
  version.
- **Verify at the seam.** Protocol changes get deterministic transport-level tests
  (socketpair round-trips through the real sender/receiver) covering success, non-zero
  exit, timeout, output-cap abort, and policy-disabled rejection. Event-driven waits, never
  timing-based sleeps ([TESTING.md](TESTING.md)).
- **Sandbox-forward.** The host side is in-process VZ API and must stay sandbox-safe
  ([SANDBOX.md](SANDBOX.md)); nothing about exec may tempt a host-side `Process` spawn or a
  new entitlement.
- **Log at the right level.** Command ran / exited / aborted at `.notice` *without command
  text or output* (§7); command content and output only at `.debug`.

---

## Using this document

When you pick up a guest-exec issue or write new guest-exec code, check the change against
these principles in order:

1. Is the only invocation path Kernova's own UI and process (§1)?
2. Is it off by default, per-VM, and enforced by the guest agent (§2)?
3. Can the guest user see it and stop it (§3)?
4. Does it run strictly as the guest login user, with no new TCC grants (§4)?
5. Is the wire format argv-first, with shell execution an explicit separate mode (§5)?
6. Does it keep host secrets out of command content (§6) and treat replies as untrusted,
   bounded, non-persisted data (§7)?
7. If it needs more than that — programmatic invocation, root, a PTY, a network — did it
   update this document first (§8, Non-goals)?

If a principle here turns out to be wrong, fix the principle here first — then the code.
