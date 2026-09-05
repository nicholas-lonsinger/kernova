# Which channel a sandboxed CLI can reach a running GUI app on

**Date:** 2026-09-05 · **Host:** macOS 27.0 (Darwin 27.0.0), Xcode 27 toolchain, one Mac, one user (uid 501), Remote Login off · **Reader:** anyone shaping a channel between an out-of-process client and the app (#996, #307, #308)

## Read this first

Two probes, each a few dozen lines of C, run once on one machine. The
launchd-domain behaviour is Apple-documented and the probe only confirms it;
the sandbox behaviour is observed, not specified, and the retest recipe at
the end is what the next reader should re-run before building on it.

## Summary

- An app cannot publish a Mach service dynamically. `xpc_connection_create_mach_service`
  with the listener flag performs a launchd check-in, and launchd refuses the
  name unless a launchd job owns it. The only XPC shape is a launchd agent.
- A launchd agent's services live in the login-session domain `gui/<uid>`.
  An SSH shell runs in the per-user domain `user/<uid>`, which is the
  *parent* of `gui/<uid>`, and lookups walk child to parent only. Nothing an
  agent publishes is reachable from SSH.
- A sandboxed process with an app-group entitlement can `bind`, `listen`,
  and `accept` on an `AF_UNIX` socket inside that group container, and a
  second sandboxed process in the same group can `connect` to it. Neither
  side holds `com.apple.security.network.client` or `.server`.
- Each side reads the peer's `audit_token_t` with `getsockopt(SOL_LOCAL,
  LOCAL_PEERTOKEN)`, resolves it to a `SecCode` via `kSecGuestAttributeAudit`,
  and can read the signing identifier and team and evaluate a `SecRequirement`
  against it. That is the caller identity an authorization check needs.
- A group container is only granted when the group ID starts with the
  signature's team ID. An unprefixed ID, or an ad-hoc signature with no team,
  is rejected by `containermanagerd` and every later file operation in the
  container fails with `EPERM`.
- A sandboxed standalone executable needs an embedded Info.plist carrying
  `CFBundleIdentifier`, or `secinitd` kills it at launch before `main`.

## Observations

### Dynamic Mach registration is refused

A non-sandboxed listener calling `xpc_connection_create_mach_service("app.kernova.probe", NULL,
XPC_CONNECTION_MACH_SERVICE_LISTENER)` from a Terminal-descended shell, then a client in the
same shell calling the same function with no flags and sending a message with reply:

```
launchd  [gui/501 [101036]:] failed activation: name = app.kernova.probe, flags = 0x0, requestor = listener[88910], error = 1: Operation not permitted
launchd  [gui/501 [101036]:] failed lookup: name = app.kernova.probe, requestor = client[90125], error = 3: No such process
```

Both sides received `XPCErrorDescription = "Connection invalid"`. The listener never held the name.

### Domain topology

`launchctl print user/501` reports `session = Background` and `subdomains = { gui/501 }`;
`launchctl print gui/501` reports `type = login`, `session = Aqua`. `sshd` sessions are
Background-session processes and land in `user/501`.

### Sandboxed AF_UNIX in a group container

Probe binary signed with `Apple Development` (team `8MT4P4GZL2`), entitlements
`com.apple.security.app-sandbox` and `com.apple.security.application-groups =
["8MT4P4GZL2.app.kernova.probe"]`, Info.plist embedded via
`-sectcreate __TEXT __info_plist`, socket path from
`containerURL(forSecurityApplicationGroupIdentifier:)` plus `probe.sock`:

```
server listening on ~/Library/Group Containers/8MT4P4GZL2.app.kernova.probe/probe.sock
peer pid 24564 uid 501
peer signing identifier=app.kernova.sockprobe team=8MT4P4GZL2
requirement check: PASS (0)
server got: ping
```

The client printed the mirror image and `client got: pong`.

Two earlier failures on the way, each a fact of its own:

- Ad-hoc signature, group ID `group.app.kernova.probe`: `containermanagerd` logged
  `REJECTED. Requestor's signature does not allow it to access a TCC-protected group container.
  Group containers identifiers should be prefixed by requestor's team ID to allow access on this
  platform.` The API still returned a path; `bind` there failed `EPERM`.
- No embedded Info.plist: exit 133 at launch, `secinitd` logging `Unable to get bundle
  identifier for container id app.kernova.sockprobe: Unable to get bundle identifier because
  Info.plist from code signature information has no value for kCFBundleIdentifierKey.`

Re-signing an already-run tool with a different signer prompts once for its container
(`"(null)" differs from previously opened versions`); `Open Anyway` is the answer for a probe.

## Retest recipe

1. Build `listener.c` / `client.c` around `xpc_connection_create_mach_service` as above, unsigned;
   run the listener in a Terminal shell, the client in another. Expect `Connection invalid` and
   the `failed activation` line under `log show --predicate 'process == "launchd"'`.
2. Build one C tool with `server`/`client` modes over `AF_UNIX`, embed an Info.plist, sign with a
   team identity and the two entitlements above using a team-prefixed group ID, run server then
   client. Expect the exchange and the peer signing lines.
3. With Remote Login on, run the client from `ssh localhost` for the same-machine SSH case; this
   run had Remote Login off and relied on the documented domain topology for that step.
