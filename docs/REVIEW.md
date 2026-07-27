# REVIEW.md

Read before filing a review-debt issue or writing an annotation. The four triage categories and the severity bar itself are in [AGENTS.md](../AGENTS.md#review-feedback-handling); this file is the procedure — the bar's worked examples, the issue template and labels, issue hygiene, and the `RATIONALE:` / `periphery:ignore` formats.

## Severity-bar signatures that default to Dismiss

Escalating one of these to **Annotate** takes a pattern *actually* re-flagged across reviews, and an annotation clearing all four conditions in [Intentional pattern annotations](#intentional-pattern-annotations).

- **Hypothetical future code** — "a future caller or method could bypass X." Unwritten code can't be defended against with access control; document the invariant where it lives instead.
- **Adversarial scheduling** — a race needing timing no real user or system flow produces, with a bounded, benign outcome (one spurious retry). If you are unsure the flow can produce it, that investigation *is* the triage: do it before filing, not after.
- **Degenerate inputs** — inputs no real workflow produces (same-name-differing-only-by-case bundles dropped together), failing recoverably.
- **Pre-existing behavior surfaced by an unrelated diff** — verify against the merge base before attributing. It is a finding against *this* change only if the change introduced or worsened it; otherwise it is at most a new issue on its own merits, judged by the same bar.

## Review debt tracking

Valid findings **out of scope** for the current task are captured as GitHub issues, never silently dropped: bugs, correctness and logic errors, security concerns, performance issues, meaningful refactors and non-trivial code smells, and missing coverage on critical paths — each still clearing the severity bar.

**File immediately**, as part of the review flow and before summarizing results — do not list a qualifying finding as "skipped" and wait to be asked. Check for an existing issue first, group findings sharing a root cause into one, and name what you filed in the task summary. Titles are actionable and specific ("Add error handling for disk-full scenario in BundleManager", not "Improve error handling").

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

### Labels

The inventory lives on GitHub — run `gh label list` and pick by the descriptions there, which are the source of truth. The structural rules that don't fit in a label description:

- Labels come in three prefix families — `Type:` (mirrors the commit type prefixes), `Area:` (subsystem), `OS:` (guest-OS support) — plus standalone flags (`Review Debt`, `Dead Code`, `Performance`, `Security`). Apply at most **one label per family**; families compose freely.
- Every issue gets a `Type:`, and an `Area:` when it clearly belongs to one subsystem.
- `Review Debt` marks the *origin* (filed from a review) while `Type:` carries the category; code-smell and duplication findings are `Type: Refactor`. Performance and security findings add that flag on top of their `Type:`.
- `Dead Code` is applied automatically by `dead-code.yml` to its scan-tracker issues; use it for manually-filed dead-code findings too.

## Issue hygiene

These apply to **every** issue you file, so the body stays useful until the work is picked up.

- **Report, don't diagnose.** State observed behavior and verifiable facts — what happened vs. what was expected, reproduction steps, exact error text or log excerpts, the symbols involved. A diagnosis baked in at filing time anchors whoever picks it up on a theory that may already be stale. A defect you verified in the code during review **is** a fact: state it with its evidence, and don't extrapolate past what you verified.
- **A causal theory needs a caveat heading.** One earned by significant investigation — a traced code path, an instrumented repro, a bisect — may be included under an explicit `## Hypothesis (unverified — re-verify before acting)` heading stating the evidence and how it was obtained. A theory from a quick read stays out entirely.
- **Keep it to what and why** — summary, motivation, scope, considerations, open questions. No "Files likely involved" sketch or other forward-looking file/API/wiring plan; design that when the work starts. If you deliberately omit one, say so in a line ("design when picked up") so a future reader knows the omission was intentional.
- **Never cite a line number** — they drift within an edit or two. Name the **symbol** (`startSerialReading()`, `capturesSystemKeys`): it survives edits and is greppable. Expect your own type and file names to be renamed anyway; Apple's (`VZ…`, `NSPasteboardItemDataProvider`) are stable and fine to cite as the *what*.
- A bug report's `## Location` field is the exception to "no file refs" — it is the finding's evidence. Keep it, by symbol rather than line number.

## Intentional pattern annotations

A `RATIONALE:` comment records **why a specific alternative was rejected**, so a future reader can re-evaluate that trade-off without redoing the investigation. Reading one — it is evidence, not authority — is covered in [AGENTS.md](../AGENTS.md#review-feedback-handling); this is how to write one.

It is a **last resort**, not the routine outcome of **Annotate**: the population only ever grows, each one taxes every future reader, and an unverifiable one is worse than no comment because it gets believed. Most findings reaching this point should be **Dismissed**.

### All four must hold

1. **Actually flagged, or actually attempted.** Either a review (human or automated) raised this specific concern, or you wrote the obvious alternative and it demonstrably failed. "A reviewer *would* reasonably flag this" is **not** enough — that is true of most non-obvious code, and pre-emptive self-defense is how these accumulate.
2. **No better home.** Each of these beats a comment, in order:
   - **A test that fails when the constraint changes.** A comment asserting "this must stay sequential" rots silently; a test named for the constraint cannot. Prefer this whenever the constraint is observable.
   - **Restructuring so it stops looking wrong** — a rename, an extracted helper, or a named constant often removes the objection outright.
   - **AGENTS.md or a `docs/` file**, when the reason is project-wide rather than local to one call site. State only the local fact the reader cannot derive from the doc.
3. **Cites re-checkable evidence** — a PR or issue number, a named test, a vendor-doc URL, or a dated first-hand observation (`verified 2026-07-20 via log stream`). A bare assertion about framework, OS, or hardware behavior does **not** qualify; that is exactly the class that goes stale invisibly while still being trusted. With nothing to cite you have a hypothesis, not a rationale: leave the code unannotated, or file it under the `## Hypothesis` heading above.
4. **Consequential.** "Fixing" the pattern breaks something real. If the worst case is a style regression, dismiss instead.

**Format** — name the alternative it displaces, state the constraint that makes the shipped form required, then the evidence and its date:

```swift
// RATIONALE: `nonisolated(unsafe)`, not `@MainActor` — VZVirtualMachine delegate
// callbacks are not actor-isolated by the framework, so we bridge back via
// MainActor.assumeIsolated. (VZVirtualMachineDelegate docs; Swift 6 requires a
// synchronous witness to carry its requirement's isolation.)
nonisolated(unsafe) func guestDidStop(_ virtualMachine: VZVirtualMachine) {
```

State *the constraint that makes this form required here*, never *what the code does* — if the prose reads the same without the prefix, drop the prefix. `grep -rn "RATIONALE:"` audits every one; run it periodically to prune, not only when writing a new one.

## Periphery directives

When the dead-code scan flags a symbol that is alive through machinery its symbol graph cannot see, annotate the declaration with `// periphery:ignore - <reason>` instead of deleting it. The invisible paths: protocol witnesses invoked by compiler-emitted code (string interpolation, `Codable`), members reached through type inference on argument labels, declarations referenced only from a test target the scan does not index, and symbols intentionally retained for API symmetry.

Annotate freely here, unlike a `RATIONALE:` — the scan re-raises the symbol deterministically on every run, and the reason is a statement about this codebase's own wiring that any reader can verify.

- **Annotate** when the symbol is used through one of those paths, or when the surface is intentionally complete (all `os.Logger` levels exposed even if one isn't called today).
- **Fix** when the finding is real — delete the symbol, or demote `public` to `internal` if only the access level is redundant.
- **Dismiss** never applies: every annotation carries a reason, since silently retained symbols become a maintenance hazard.

**Format** — put the directive **between** the doc comment and the declaration so DocC still associates the doc with the symbol, and keep the reason in the same comment block, with no blank line after the directive:

```swift
/// `true` when no buffered bytes remain.
// periphery:ignore - Used by `VsockFrameTests` via `@testable import`,
// which Periphery's scheme-based scan doesn't currently index for the
// SwiftPM package test target.
var isEmpty: Bool { buffer.count == readOffset }
```

Audit with `grep -r "periphery:ignore"` and drop any whose machinery has since become visible to Periphery. Prefer per-symbol annotations over re-toggling broad config flags like `retain_public` — see `.periphery.yml`.
