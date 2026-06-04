# Review Feedback Handling

Every review finding — from review tools (`/simplify`, `/review-pr`, …), post-implementation review agents, external PR review feedback (bot or human), or code noticed while working on adjacent areas — is triaged into **Fix now / Fix later / Annotate / Dismiss**. The triage table lives in [CLAUDE.md](../CLAUDE.md#review-feedback-handling); this file is the reference for the two categories that carry procedure: filing review-debt issues and annotating intentional patterns.

## Review Debt Tracking

Valid findings that are **out of scope** for the current task must be captured as GitHub issues rather than silently dropped.

**What to capture** (important + moderate severity):

- Bugs, correctness problems, or logic errors
- Security concerns
- Performance issues
- Meaningful refactoring opportunities or non-trivial code smells
- Missing test coverage for critical paths

**Issue format:**

~~~bash
gh issue create \
  --title "<concise description of the finding>" \
  --label "<review-debt/label>" \
  --body "$(cat <<'EOF'
## Found during
<PR #N / review of `FileName.swift` / context description>

## Description
<What the issue is and why it matters>

## Location
<File path(s) and line number(s) or function name(s)>

## Suggested fix
<Brief suggestion if one is obvious, otherwise omit this section>
EOF
)"
~~~

**Labels** — use the most specific match:

| Label | When to use |
|-------|-------------|
| `review-debt/bug` | Correctness issues, logic errors, potential crashes |
| `review-debt/security` | Security concerns, unsafe patterns |
| `review-debt/performance` | Inefficient code paths, unnecessary allocations |
| `review-debt/refactor` | Code smells, duplication, poor abstractions |
| `review-debt/test-gap` | Missing or insufficient tests for critical code |

**Guidelines:**

- **File issues immediately** — do not list qualifying findings as "skipped" and wait for the user to ask. If a finding meets the severity criteria above, create the issue as part of the review flow before summarizing results.
- Always check for existing issues before creating duplicates.
- Reference the source PR or file context in the issue body.
- Keep issue titles actionable and specific (e.g., "Add error handling for disk-full scenario in BundleManager" not "Improve error handling").
- When multiple related findings exist, group them into a single issue if they share a root cause.
- Issues serve as durable context — when a fix is deferred, the issue should capture enough detail to address it later without rediscovery.
- After creating issues, mention them in the conversation so the user is aware.

## Intentional Pattern Annotations

When a review flags code that *looks* wrong or unconventional but is **intentionally correct** for a project-specific reason, add an inline comment with the `RATIONALE:` prefix explaining why. This prevents the same pattern from being re-flagged in future reviews.

**When to annotate:**

- The code contradicts a general best practice but is correct here due to framework constraints, performance requirements, or architectural decisions
- A reviewer (human or automated) would reasonably flag this without project-specific context
- The reason is not already documented in CLAUDE.md, ARCHITECTURE.md, or an adjacent comment

**Format:**

```swift
// RATIONALE: VZVirtualMachine delegates are not actor-isolated by the framework,
// so we use nonisolated(unsafe) and bridge back via MainActor.assumeIsolated.
nonisolated(unsafe) func guestDidStop(_ virtualMachine: VZVirtualMachine) {
```

**Guidelines:**

- Keep annotations concise — explain *why* the pattern is correct, not *what* the code does.
- If the same rationale applies project-wide (not just at one call site), consider adding it to CLAUDE.md or ARCHITECTURE.md instead of repeating the comment on every instance.
- `RATIONALE:` comments are greppable — use `grep -r "RATIONALE:"` to audit all intentional deviations.
- Do not use `RATIONALE:` for general explanatory comments — reserve it strictly for patterns that would otherwise be flagged as issues.

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

- Keep the rationale on the same comment block as the directive — multi-line if needed, but no blank line between `// periphery:ignore` and the reason text.
- Greppable via `grep -r "periphery:ignore"` for periodic auditing — when the underlying machinery becomes visible to Periphery (e.g. a scan-coverage gap is closed), revisit the annotations and remove any that are no longer needed.
- Prefer per-symbol annotations over re-toggling broad config flags like `retain_public` — see `.periphery.yml` for the project-level guidance.
