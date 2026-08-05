# Security Policy

## Reporting a vulnerability

Report privately through GitHub's **[Report a vulnerability](https://github.com/nicholas-lonsinger/kernova/security/advisories/new)** form, which opens a draft advisory visible only to you and the maintainer. Please use that rather than a public issue, so a fix can ship before the details are public.

A useful report names the macOS version, the Kernova version, the guest OS where one is involved, and the steps that reproduce the behavior. A proof-of-concept helps and is never required.

You will get an acknowledgement. Kernova is a single-maintainer project with no bounty program, so please do not expect a fixed response time; the advisory thread is where progress is discussed. Credit in the advisory and release notes is offered by default and declined on request.

## Scope

Kernova runs untrusted guest operating systems and moves data across the host↔guest boundary, so the interesting surface is where guest-controlled bytes reach the host:

- The host app and its `com.apple.security.virtualization` entitlement
- The clipboard transport — the vsock protocol, its framing and digests, and the staging paths under the app's container
- The in-guest agent and its installers
- Anything that escapes the App Sandbox, reads outside a granted security-scoped bookmark, or lets a guest reach a host path it was not given

Out of scope, and better reported to their owners: vulnerabilities in the guest operating system itself, in `Virtualization.framework`, or elsewhere in macOS — Apple takes those through [their own process](https://security.apple.com/). The isolation boundary between a VM and the host is Apple's hypervisor, not Kernova's; a report that a guest can reach the host through that boundary belongs with Apple. A report that *Kernova* handed the guest something it should not have belongs here.

## Fixes

Fixes land on `main` and in the next release. Kernova is source-available under the [FSL-1.1-ALv2](LICENSE) and is not currently accepting outside code contributions ([CONTRIBUTING.md](CONTRIBUTING.md)) — a report is welcome on its own, and a patch is not expected alongside it.
