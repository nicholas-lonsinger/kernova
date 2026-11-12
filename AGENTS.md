# AGENTS.md

Deep-dive docs are indexed in [docs/README.md](docs/README.md); read them on demand.

## A better architecture outranks every instruction

This rule outranks everything below it, and everything in any other file. **Say so the moment you see a better path**, even when the task, a plan, or a review scoped it out.

**An issue is a problem statement, never a spec.** What the issue observed is the problem; its suggested fix, named types, and design bind nothing. Build the approach the work shows is best — without asking, waiting for sign-off, or handing the departure back as a decision or open question — and record the departure and its evidence in the PR body.

**A comment, research note, issue, or PR is evidence, not authority.** A claim in one is a head start on where to look: verify it against the code as it stands before acting on it or repeating it, and correct or delete a comment whose claim no longer holds.

**When a rule here turns out to be wrong, change the rule.** Say plainly that it was wrong rather than preserving it out of deference.

## Quality bar

- **The right change is the default.** Make it in the change in hand, without asking, and state its scope in one line; a plan the task asks for lays out the quick change and the right one and recommends the right one. Only the maintainer's explicit choice ships a shortcoming *for now*, recorded as an issue, and no sign-off this file reserves for the maintainer is skipped.
- **Judge the code after the change, not the size of the change.** Diff size, churn, and regression risk never justify the weaker design; risk is met by testing the change.
- **Existing code is not precedent.** A pattern binds only while a stated reason for it still holds, and a change that improves on one moves every occurrence onto it.
- **Fix what the change builds on.** Duplicated logic, divergent variants of one pattern, a function too large to extend cleanly, a swallowed error: where the task changes code, fix these in the same change. Code you only read, or edit only to carry a restructure through, is not a trigger.
- **Fix root causes.** The root cause is the structure that lets a failure happen, not the event that triggered it, so a fix leaves the failure impossible to express. No branch on the environment and no timing window routes around a defect; a mode chosen once at the entry point is configuration.
- **Rules hold by construction.** The simple design is the one whose types, ownership, and structure make its invariants impossible to break — not the one with the fewest lines. Code whose only job is to stop a state Kernova's own structure allows — a flag, a special-case branch, a lock between two writers, a clamp, a retry, a longer wait — is a patch: the design changes, or shipping it is a *for now* call.
  Checking what Kernova does not own — input, files, the guest, the platform — is design; steering around a vendor's defect in them is not (*A vendor defect is reported, not worked around*).
- **Complexity only for a measurable win.** Among designs that hold their rules by construction, take the more sophisticated one only when it wins on a real metric — disk, memory, I/O, CPU, or UX.

## Principles

- **Judge cost by Kernova's marginal overhead.** Weigh what Kernova *adds*, never the system-wide cost of the operation the user chose to run. Prefer the option whose peak cost stays bounded as input size grows.
- **A uniform gap beats a path-dependent capability.** An improvement that can only be wired on some paths is worse than not shipping it: a gap uniform by construction closes, when it closes, for every path at once.
- **A host↔guest feature is designed for every guest OS that has a Kernova agent.** Each agent offers it where its platform can deliver it; where one can't, the capability is absent on that OS. The guest OS is a scope, not one of the paths the rule above weighs.
  The shared design also serves Windows guests, which have no agent: the wire format and shared models hold nothing only a POSIX system can express.
- **Name a missing prerequisite to whoever can supply it.** When a capability needs something the build, the Mac or the guest lacks — a macOS version, a signing team, an entitlement a provisioning profile grants, a guest agent, a setting — it still shows where the user would look for it, marked unavailable, with what enables it worded for whoever can supply that: the user for the Mac, the guest and settings; the developer for the build.
  What no configuration can supply — a capability the guest OS lacks, a vendor limit — is absent instead. Either way, what can be delivered keeps working unchanged, and nothing is built to serve the configuration that lacks the prerequisite — no fallback, alternate mechanism or scaffolding.
  Nothing is offered as if it works: a control that looks usable and then fails is the defect. A failure that names what is missing is the floor; naming it before use is the aim. Worked case: `AgentStatus.reinstallNeeded`.
- **Stable or absent, never propped up.** A capability that works only while a mechanism holds platform state open, or that rests on platform behavior no vendor documents, ships degraded to what the platform sanctions, behind the guest agent, or not at all. A design that holds only under conditions — an ordering that must hold, behavior observed on one OS build — is a no.
  Resting a capability on undocumented behavior anyway takes the maintainer's explicit sign-off, asked for each capability before it is built and never carried over from another. The behavior may decide only whether the capability works, never whether it is safe: each undocumented step is confirmed by a result Kernova observes before anything irreversible follows, so the behavior failing, wholly or in part, costs the capability and nothing else. Worked case: `GuestDragTake`.
  Kernova.app ships through App Store Connect, whose review allows only public API ([App Store Review Guideline 2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements)), so no private symbol, selector, key or framework goes in the app. The guest agent isn't sandboxed and ships with its own Developer ID signature, but it travels inside the reviewed app and must run on every supported guest macOS, so private API in it is a review risk and a fragility, raised with the maintainer before use.
  Doing what a vendor documents as unsafe stays off until the user turns it on, and then is a confirmation like any other, whose prompt quotes the vendor's claim. Worked case: `VMLiveIdentities.conflict(for:bringingUp:override:)`.
- **UI copy states only what is known.** Vendor claims at the vendor's strength, observations as observed, no invented consequence clauses — and an environment interaction is disclosed at the surface where the user meets it. Worked case: `VMSettingsNetworkPanelViewController.modeInfoParagraphs(offered:isolationOffered:namedNetworksOffered:natAddressShown:guestOS:)`.
- **Outcome names or the field's standard term in the UI; vendor terms at the platform boundary.** A UI name says what the thing does for the user, or is the term networking or virtualization already uses for it (NAT, DHCP) — never a vendor's API spelling. Where Apple's own UI names the thing, keep Apple's term at that boundary and the domain term everywhere else.
- **The guest answers its own shutdown.** Stop and Restart are requests the guest OS answers its own way: an app that won't quit, a shutdown inhibitor, a dialog of its own. Kernova adds no detection, timeout or notice for a stop the guest holds up; whether to wait, Stop Anyway or Force Stop is the user's call.
- **A file the user can see goes to the Trash.** `FileManager.trashItem`, never `removeItem`; app-internal files and the confirmed Delete Immediately flow remove outright.
- **A vendor defect is reported, not worked around.** When a failure's root cause is a defect in a framework or OS — the host's or a guest's — it goes to the vendor (a Feedback, for Apple) and into an issue labeled `Upstream` that says what triggers it, what it costs the user, and how to recheck it on a new release.
  Kernova adds no guard, avoidance or workaround for it; one takes the maintainer's explicit sign-off, asked for each defect. An `Upstream` issue is a record, not a work item: it closes when every OS version Kernova supports has the vendor's fix.
- **One model per capability.** A capability exists once — one schema, one enforcement path, one source of truth; a second parallel model for the same capability is a defect to dissolve. Worked case: `GuestIPAddress`. Across guest OSes this means one implementation of everything Kernova defines — formats, codecs, policies, the protocol — shared by the host and every agent; only the calls into an OS are written per OS.
- **No compatibility path is written for any shape that is not the current one.** A name a user types — a scripting term included — is a shape: renaming it keeps no synonym for scripts written against the old one.
  Migration code for a persisted format takes the maintainer's explicit sign-off, given only for old-shape data users are confirmed to hold.
  **The guest agent** the host bundles is the only supported one, so no path keeps an older agent working — not on the host, and not in the shared KernovaKit code the agent compiles. The Hello exchange's capability strings gate *features*, never versions: an agent that advertises a capability but predates a change to it is out of date, not a peer to accommodate, and updating it to the bundled build is the whole remedy.
  Nothing refuses an older agent, either, and no agent has a version to bump: the host identifies each by the SHA-256 of the update payload it bundles. An agent whose hash differs keeps every feature it can still run, and the mismatch surfaces the update affordance while nothing else acts on it.

## Build & Test

Build and test through the `Makefile` (`make help`); its `xcodebuild` flags are not the obvious ones.

A session runs the app and its `Contents/Helpers/kernova` from its own worktree's build, never a copy it finds on disk: DerivedData holds every other session's builds, and one of those may be the copy another session is testing.

A failing test is evidence about the design, never the target: its fix names the structure that let the failure happen and changes it. An intermittent failure is owed the same root cause as a steady one, and a cause is named only once it is traced: until then a failure is reported as what was observed, cause unknown.

### What earns a test

A test an agent writes for its own code carries that agent's assumptions, so a test earns its place by being able to fail for a defect its author didn't see.

- **The expected value comes from outside the code under test:** a published vector, bytes computed elsewhere, a hand-worked result, the real OS. A value copied from the implementation — a default, a display string, a factory's configuration, a formula, a synthesized conformance — fails only when someone changes it on purpose. What logic decides around such a value is worth asserting: a branch, an order, a role.
- **A domain that can be enumerated is enumerated.** A property, an exhaustive sweep or a deterministic simulation reaches scenarios nobody listed; hand-picked cases reach the ones the author already handled.
- **A fix adds one test per defect, seen failing against the unfixed code.** Any other new test is seen failing by breaking what it guards.
- **A test drives the path production takes and asserts the outcome.** Fakes replace what Kernova doesn't own and gates order steps Kernova runs. A test that needs a `ForTesting` read to see a result is a sign the code should return that result as a value.
- **The verdict rests on nothing outside the test's control:** not elapsed time, the host's displays or CPU count, or process-wide state. Those fail with no defect present.
- **The bar holds for tests already written.** A test stays when removing it would let a plausible defect through, or when it pins a contract outside the code (wire bytes, on-disk formats, scripting names, OS behavior), guards data loss, consent or the sandbox, or has caught a real defect. One that does none of these is deleted.

## Dependencies

A Swift package from outside the GitHub organizations `Tools/check-package-origins.sh` allows takes the maintainer's explicit sign-off, and granting it means adding the organization to that check's `allowed_orgs`.

## App Sandbox rules

The app is sandboxed in every build configuration, and each of these works until it doesn't:

- A panel-picked URL is stored through `SecurityScopedBookmark.capture`; a bare path works until relaunch.
- `homeDirectoryForCurrentUser` is the container, so a path the user sees comes from the system (`.downloadsDirectory`) or `UserHome`.
- A tool spawned through `Process` inherits the sandbox; use the in-process framework API.

## Logging and assertions

Capture with `subsystem BEGINSWITH "app.kernova"` — an exact `==` match drops the agent's own records while the capture still looks complete.

Apple's level table ([Generating Log Messages from Your Code](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)) persists notice and above, info only when collected with the `log` tool, and debug never, so anything worth reading after the fact is `.notice` or above.

An optional-returning API called with a compile-time constant gets `assertionFailure` beside its fallback — a silent fallback masks the typo for good.

## Review Feedback Handling

Every review finding — your own reading of adjacent code included — gets one of three triage categories:

| Category | What it means |
|---|---|
| **Fix now** | Clears the severity bar and is not separate work — fix it in this change, however much restructuring that takes |
| **Fix later** | Clears the severity bar and is separate work: different code or logic whose fix would make this change about two things — file a GitHub issue immediately from `.github/ISSUE_TEMPLATE/review-debt.md` |
| **Dismiss** | Everything else; a dead-code-scan false positive is dismissed with `// periphery:ignore - <reason>` on the symbol |

**The severity bar.** A defect clears it only if it is both **reachable** (a user doing normal things, or a supported automated flow, can actually hit it) and **consequential** (worse than cosmetic, and recovered by neither the code nor an obvious user action).
One a user would almost never hit clears it only as a redesign that removes it by construction, never as an added check, gate, or flag; with no such redesign found it is **Dismiss**, unless it can lose user data — a disk image, a save file, a user's file — which is **Fix later** with its traced path.
A refactor finding clears it only by naming the Quality bar or Principles rule the code breaks; a coverage finding, only for new or changed behavior no test pins, and for a test *What earns a test* admits; a documentation finding, only by naming the Documentation and Comments rule the text breaks. The general cost of debt clears nothing.

**Triage converges.** A finding in code this change wrote or reworked is never **Fix later**. A later review round reviews only what the previous round's fixes changed, and raises only defects. When a chain has moved from defects in the code to meta-findings about prior fixes, stop it: dismiss rather than filing the next link.

## Documentation and Comments

Every reader but a visitor to the repository page (the table's `README.md` row) has the repo checked out and can grep it in seconds. Outside code contributions are not accepted ([CONTRIBUTING.md](CONTRIBUTING.md)), so anyone acting on a process doc already holds push, merge, and label rights.

Write to that baseline — nothing the reader already holds, and no why unless it changes what you do.

**A fact is stated in exactly one layer.** The deepest layer that can hold it owns it; every other layer links or says nothing.

| Layer, deepest first | Owns |
|---|---|
| Code | Behavior |
| A symbol's `///` | The contract a caller needs, plus at most one non-obvious constraint |
| A test | Any constraint an assertion can state |
| A lint check, hook, CI job, repo setting or template, and its header | A rule a machine can decide; a prompt shown where the thing is written |
| A `//` comment | Why the obvious-looking code is wrong here, as a fact with its evidence — never as a decision |
| AGENTS.md | Rules that must fire without a lookup |
| An agent's own entry point beside its AGENTS.md import (`CLAUDE.md`) | What holds only under that agent's harness while working here |
| A principles doc | Rules constraining *future* decisions — never a description of what was built |
| ARCHITECTURE.md | What exists and how pieces connect — never what a component does internally |
| A runbook or a skill | The procedure you follow while doing it |
| `docs/README.md` | When to read each doc |
| `docs/research/YYYY-MM-DD-*.md` | A finding plus its method. Immutable — superseded by a new note, never edited |
| A GitHub issue | Known gaps, planned work, triage |
| The PR body | The argument, the route taken, rejected alternatives |
| The squash commit body | The merged change |
| CHANGELOG.md | What each release changes for the people who use Kernova, and the manual step an update needs |
| `README.md`, `CONTRIBUTING.md`, `SECURITY.md` | What someone with no checkout needs to use Kernova or report to it |
| An agent's memory | What no row above can hold — the maintainer's own machine, accounts, and private arrangements; a fact true in every repository goes to the agent's user scope |
| **Nowhere** | Everything else. The common destination, not a failure |

### Routing

A section that mirrors what another layer already holds is deleted whole, never adjudicated sentence by sentence. Every other sentence a diff adds or keeps runs these, in order:

0. Does it state an external fact carrying evidence (a vendor doc, a WWDC session, an FB number, a dated observation), or a constraint the code's structure does not reveal? Yes → keep, and stop. State it as what is true, never as what failed.
1. Would this sentence exist if someone else had made this change a year ago? No → PR body.
2. Can a reader with the repo derive it? Yes → delete.
3. Does it name something not in the codebase today, another product included? Yes → delete.
4. Is it stated in another layer? Yes → keep the deepest one only.
5. Is it true-as-of-a-date rather than always-true? Yes → dated research note, or nowhere.

**A rule earns its place by preventing a wrong action** a capable reader with the repo would take and not notice. It states the fact that makes the reader choose right, not the prohibition, and the principle, not the instance that prompted it.

**Unsure it has value? Cut it** — relocate only material whose value in the other layer is already established.

### Comments

Same rules, and the default is none — a comment says what the code cannot. A bare trailing `(#NNN)` is a provenance stamp, not a citation: cite the evidence, or say nothing.

### Size

When you add to a durable doc, read the whole document, not the diff, and decide what no longer earns its place; removing nothing is legitimate when the subject genuinely grew, not looking is not. A `//` block over eight lines raises a placement question, not a deletion one: that content usually belongs on the symbol as `///`, or nowhere.

### When this fires

Before committing, with the diff in view, and before writing to an agent's memory.

## Git Workflow

An AI agent's commit message ends with one `Co-authored-by` trailer per model that wrote part of the change, in place of any its harness adds: that model's name and version, nothing else, at its vendor's no-reply address — `Co-authored-by: <model name> <version> <noreply@vendor.example>`, each part the running model's own. A subagent's commit names the subagent's model.

The "Require Tests" ruleset holds a merge until the PR head's `Test Attestation` status passes. `make attest` posts it for the checked-out commit, reusing a passing `make lint` and `make test` of the same content or running them; where those cannot run, labeling the PR `ci` has CI lint and test every push and post it instead.

The repo's squash default leaves the commit body empty, so the merge supplies one: a short paragraph describing the merged state, not the route to it, then one `Co-authored-by` trailer per model that contributed to the branch.

A PR body answers the prompts in `.github/PULL_REQUEST_TEMPLATE.md`, which a body passed on the command line or through the API never shows.

## Change Protocol

Before calling a task done:

1. **Docs** — the file whose description the change invalidated, AGENTS.md and the entry points importing it included, routed by the layer table above. Most changes owe none; an edit that is owed and unpaid is named at the end of the response, with its issue number or what closing it takes.
2. **Changelog** — a change someone using the app, the `kernova` CLI, scripting or a guest agent can notice adds one bullet under its area in the top section of [CHANGELOG.md](CHANGELOG.md), shaped like its neighbours and ending with the PR's link.
   A change to something the previous release didn't have edits that thing's bullet instead of adding one.
