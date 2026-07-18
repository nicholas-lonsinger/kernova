# REVIEW.md

The full review-feedback machinery: the severity bar with worked examples, the review-debt issue process, issue hygiene, and the `RATIONALE:` / `periphery:ignore` annotation formats. The four triage categories (**Fix now** / **Fix later** / **Annotate** / **Dismiss**) and the severity-bar summary are in [AGENTS.md](../AGENTS.md#review-feedback-handling) — this file is what you consult when actually filing or annotating.

## The severity bar — Dismiss and Annotate are real options

A finding earns **Fix now** or **Fix later** only if **both** hold:

1. **Reachable** — a user doing normal things (or a supported automated flow) can actually hit it.
2. **Consequential** — the outcome is worse than a transient cosmetic glitch, a logged self-recovering retry, or a state an obvious user action recovers from.

Findings with these signatures default to **Dismiss** (or **Annotate** with `RATIONALE:` when the code would otherwise be re-flagged every review):

- **Hypothetical future code** — "a future caller/method could bypass X." Unwritten code can't be defended against with access control; document the invariant where it lives instead.
- **Adversarial scheduling** — races requiring timing no real user/system flow produces, with a bounded, benign outcome (e.g. one spurious retry). If unsure whether the flow can produce it, that investigation is the triage — do it before filing, not after.
- **Degenerate inputs** — inputs no real workflow produces (e.g. same-name-differing-only-by-case bundles dropped together), failing recoverably.
- **Pre-existing behavior surfaced by an unrelated diff** — verify against the merge base before attributing: it's a finding against *this* change only if the change introduced or worsened it. Otherwise it's at most a new issue on its own merits, judged by the same bar — not part of this review's loop.

**Stop-the-chain rule:** when a finding is about the *fix for a previous review finding* and severity is declining across the chain (#487 → #490 → #492 → #493 is the canonical example — ending at "`private` doesn't stop a hypothetical future method in the same class"), do not file the next link. Dismiss or Annotate. A review that has moved from defects in the code to meta-findings about prior fixes has run out of real defects.

Recall-biased (high-effort) review runs surface uncertain findings by design — those findings especially must clear this bar before being filed.

## Review Debt Tracking

Valid findings that are **out of scope** for the current task must be captured as GitHub issues rather than silently dropped.

**What to capture** (important + moderate severity, and clearing the severity bar above):
- Bugs, correctness problems, or logic errors
- Security concerns
- Performance issues
- Meaningful refactoring opportunities or non-trivial code smells
- Missing test coverage for critical paths

**Issue format:**

~~~bash
gh issue create \
  --title "<concise description of the finding>" \
  --label "Review Debt" --label "Type: <Fix|Refactor|Test>" \
  <plus --label "Area: <subsystem>" when one clearly fits, and --label "Performance" / --label "Security" for those findings> \
  --body "$(cat <<'EOF'
## Found during
<PR #N / review of `FileName.swift` / context description>

## Description
<What the issue is and why it matters>

## Location
<Symbol/function name(s) and file path(s) — prefer names over line numbers, which drift>

## Suggested fix
<Brief suggestion if one is obvious, otherwise omit this section>
EOF
)"
~~~

**Labels** — the label inventory lives on GitHub, not in this file: run `gh label list` and pick by the descriptions there; they are the source of truth. The structural rules that don't fit in a label description:

- Labels come in three prefix families — `Type:` (mirrors the PR/commit type prefixes), `Area:` (subsystem), `OS:` (guest-OS support) — plus standalone flags (`Review Debt`, `Dead Code`, `Performance`, `Security`). Apply **at most one label per family**; families compose freely.
- Every issue gets a `Type:` label, and an `Area:` label when it clearly belongs to one subsystem.
- Review-debt issues additionally get `Review Debt` — it marks the *origin* (filed from review) while `Type:` carries the category; code smells/duplication findings map to `Type: Refactor`. Performance and security findings add the `Performance` / `Security` flag on top of their `Type:` label.
- `Dead Code` is applied automatically by `dead-code.yml` to its scan-tracker issues; use it for manually-filed dead-code findings too.

**Guidelines:**
- **File issues immediately** — do not list qualifying findings as "skipped" and wait to be asked. If a finding meets the severity criteria above, create the issue as part of the review flow before summarizing results.
- Always check for existing issues before creating duplicates
- Reference the source PR or file context in the issue body
- Keep issue titles actionable and specific (e.g., "Add error handling for disk-full scenario in BundleManager" not "Improve error handling")
- When multiple related findings exist, group them into a single issue if they share a root cause
- After creating issues, mention them in the task summary so the maintainer is aware

## Issue Hygiene

These rules apply to **all** issues you file — feature/enhancement as well as review-debt — so the body stays useful until the work is actually picked up:

- **Report, don't diagnose.** The body states reported/observed behavior and verifiable facts — what happened vs. what was expected, reproduction steps, exact error text or log excerpts, the symbols involved. Root-cause analysis is the job of whoever picks the issue up, working against the code as it exists *then*; a diagnosis baked in at filing time anchors them on an unverified (or since-stale) theory. A defect you actually verified in the code during review **is** a fact — state it with its evidence — but don't extrapolate beyond what you verified. A causal theory earned by genuinely significant investigation (a traced code path, an instrumented repro, a bisect) may be included, but only under an explicit `## Hypothesis (unverified — re-verify before acting)` heading that states the evidence and how it was obtained; a theory from a quick read stays out entirely.
- **Keep it to what/why.** Summary, motivation, scope, considerations, open questions. Do **not** include a "Files likely involved" sketch or other forward-looking file/API/wiring plan — design that when the work starts, not at filing time.
- **Never cite a line number.** They drift within an edit or two. Name the **symbol** instead (`startSerialReading()`, `capturesSystemKeys`) — it survives edits and is greppable.
- **Expect your own type/file names to be renamed.** A 2026 audit found ~7 issues pointing at things that no longer existed after the SwiftUI→AppKit rename (`VMSettingsView` → `VMSettingsViewController`, and `VMDetailView`/`VMConsoleView`/`SidebarView`/`VMRowView` gone) and the SPICE→vsock clipboard migration (`GuestClipboardAgent.swift` → `VsockGuestClipboardAgent.swift`). Apple/framework type names (`VZ…`, `NSPasteboardItemDataProvider`) are stable and fine to cite as the *what*.
- **Bug reports are the exception to "no file refs":** the `## Location` field above points at where the defect lives, which is the finding's evidence — keep it, but by symbol/method, not line number.
- If you deliberately omit an implementation sketch, add a one-line note saying so ("design when picked up") so a future reader knows the omission was intentional.

## Intentional Pattern Annotations

When a review flags code that *looks* wrong or unconventional but is **intentionally correct** for a project-specific reason, add an inline comment with the `RATIONALE:` prefix explaining why. This prevents the same pattern from being re-flagged in future reviews.

**When to annotate:**
- The code contradicts a general best practice but is correct here due to framework constraints, performance requirements, or architectural decisions
- A reviewer (human or automated) would reasonably flag this without project-specific context
- The reason is not already documented in AGENTS.md, the `docs/` files, or an adjacent comment

**Format:**

```swift
// RATIONALE: VZVirtualMachine delegates are not actor-isolated by the framework,
// so we use nonisolated(unsafe) and bridge back via MainActor.assumeIsolated.
nonisolated(unsafe) func guestDidStop(_ virtualMachine: VZVirtualMachine) {
```

**Guidelines:**
- Keep annotations concise — explain *why* the pattern is correct, not *what* the code does
- If the same rationale applies project-wide (not just at one call site), consider adding it to AGENTS.md or the relevant `docs/` file instead of repeating the comment on every instance
- `RATIONALE:` comments are greppable — use `grep -r "RATIONALE:"` to audit all intentional deviations
- Do not use `RATIONALE:` for general explanatory comments — reserve it strictly for patterns that would otherwise be flagged as issues

## Periphery Directives

When the dead-code scan flags a symbol that is alive through machinery Periphery's symbol graph cannot see — protocol witnesses invoked by Swift's compiler-emitted code (string interpolation, `Codable`), members reached through type inference on argument labels, declarations referenced only from a test target Periphery does not currently scan, or symbols intentionally retained for API symmetry — annotate the declaration with `// periphery:ignore - <reason>` instead of deleting it. This is the Periphery-specific counterpart to `RATIONALE:`: same spirit (silence a finding that would otherwise be re-raised every scan), different syntax that the tool itself recognizes.

**When to annotate vs. fix vs. dismiss:**
- **Annotate** when the symbol is genuinely used through one of the invisible paths above, OR when the surface is intentionally complete (e.g. all `os.Logger` levels exposed even if a particular call isn't used today).
- **Fix** when the finding is real — delete the symbol, or demote `public` to `internal` if only the access level is redundant.
- **Dismiss** does not apply: every annotation must include a reason, since silently retained symbols become a maintenance hazard.

**Format:**

```swift
/// `true` when no buffered bytes remain.
// periphery:ignore - Used by `VsockFrameTests` via `@testable import`,
// which Periphery's scheme-based scan doesn't currently index for the
// SwiftPM package test target.
var isEmpty: Bool { buffer.count == readOffset }
```

Place the directive **between** the doc comment (`///`) and the declaration so DocC still associates the doc with the symbol.

**Guidelines:**
- Keep the rationale on the same comment block as the directive — multi-line if needed, but no blank line between `// periphery:ignore` and the reason text
- Greppable via `grep -r "periphery:ignore"` for periodic auditing — when the underlying machinery becomes visible to Periphery (e.g. a scan-coverage gap is closed), revisit the annotations and remove any that are no longer needed
- Prefer per-symbol annotations over re-toggling broad config flags like `retain_public` — see `.periphery.yml` for the project-level guidance
