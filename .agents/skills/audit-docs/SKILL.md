---
name: audit-docs
description: Audit AGENTS.md or a docs/ file sentence by sentence — verify every declaration against the tree, keep only rules that prevent a silent wrong action a capable model would otherwise take, and report one verdict per clause. Use when asked to review, audit, or prune AGENTS.md, CLAUDE.md, or any file under docs/ for correctness or load-bearing content; read-only — it edits nothing.
argument-hint: "<file> [<file>...]"
---

Audit the file(s) named by the arguments: $ARGUMENTS

With no argument, audit AGENTS.md, then docs/README.md, then every file
docs/README.md indexes, in its order. Research notes under docs/research/ are
immutable: verify nothing in them and edit nothing, but flag any note a doc
cites whose claim current code contradicts.

Work one section at a time. Within a section, go clause by clause — no
skimming, no sampling. A table row, a list item, and each clause of a compound
sentence gets its own verdict. A table of facts is judged as a whole after its
rows: find every rule that consumes it, and if one sentence is the only
consumer, the table folds into that sentence or goes.

## Classify every clause

Assign exactly one kind before judging it:

- **Declaration** — a claim about the repo, the platform, or a vendor.
- **Rule** — tells the reader to do or not do something.
- **Principle** — steers a judgment call when no rule applies (AGENTS.md
  "Principles", DESIGN.md).
- **Pointer** — a link or "read X when Y".
- **Filler** — none of the above (onboarding prose, motivation, restating
  another layer).

## Tests by kind

### Declarations — verify, then ask whether it needs stating

Check every declaration against the current tree, not against another doc:
grep, read the code, read the xcconfig/pbxproj, run `make help`, run `gh api`
for repo settings, fetch the vendor doc for a vendor claim. Report each as
**true**, **false** (with the evidence), or **unverifiable** (say what would
verify it).

A true declaration is still deleted when a reader with the repo derives it in
seconds — a directory listing, a file header, a grep, `git log`. A false one is
not automatically a rewrite: correct it, then run the corrected version through
the same derivability test and the layer test. Most corrected declarations
belong one layer down, or nowhere.

### Rules — the model's judgment is the baseline

A rule earns its place only by preventing a wrong action that a capable model,
given the codebase and no rule, would take **and would not notice**. Three
questions, in order; the first failure sets the verdict.

1. **Would the model choose wrong?** Name the specific wrong action. If the
   rule fixes a choice the model is competent to make — when to run the full
   suite, how to phrase a commit, which helper to reuse — it replaces judgment
   with a fixed action, and the verdict is `delete`. "Good practice" and "what
   we do" are not wrong actions. A convention every neighboring file already
   follows is derivable by reading neighbors, so it is not a wrong choice
   either.
2. **Would the wrong action fail silently?** If lint, a compile error, a
   required CI check, a hook, a repo setting, or the first review catches it,
   the rule is a reminder, and reminders are deleted — a loud failure is
   caught even when it comes after an irreversible step, unless that step
   did damage. If the mechanism exists but is not yet wired (a lint that could
   check it, a repo setting that could forbid it), the verdict is
   `fix mechanism → delete`, naming the mechanism. If the rule exists because
   the tree is inconsistent and the rule picks one side, the tree is the
   defect: `fix code → delete`. What survives this question is the failure
   that looks like success — the poll loop that passes locally and flakes in
   CI, the log filter that drops records while the capture looks complete,
   the pick site that works until relaunch.
3. **Is it the right rule, in the right place?** Given the wrong action, is
   this the narrowest instruction that prevents it? State the fact that makes
   the model choose right ("the Makefile encodes flags that are not the
   obvious ones") rather than the prohibition ("never hand-write
   xcodebuild") — a model told the fact chooses right on its own, and the
   prohibition removes discretion the model would exercise well. Drop the
   method when only the outcome matters; keep it only when the method is the
   non-obvious part. Then apply AGENTS.md's layer table: a rule that fires
   only during one procedure belongs in that runbook; one that must fire
   without a lookup stays in AGENTS.md.

A rule that passes all three is **load-bearing**; say so in one word and move
on.

A violation of the rule elsewhere in the tree is evidence about that file, not
about the rule. Route the violation to the offending file's verdict list, then
gate the rule on its own merits — a rule that is both duplicated and violated
is the worst case for keeping it, not a reason to.

### Principles — different bar

A principle is exempt from question 1 by design. Instead:

- Does it discriminate? It must make some plausible option wrong, and be one
  a capable model would not land on unaided. A principle every reasonable
  design already satisfies decides nothing — delete.
- Is it stated as a decision rule (given A vs B, choose the one that…) rather
  than a value? Rewrite if not.
- Does the worked case it cites still exist and still exemplify it? Verify.
- Do two principles contradict without a stated tiebreak? Flag.

### Pointers

Target exists, the anchor resolves (lint strips anchors, so check by hand),
and the read-trigger is accurate. Then the layer test: a pointer whose target
docs/README.md already routes to with the same trigger is a duplicate, and
a pointer to a doc that itself links onward to the same place is one hop too
many.

### Filler

Delete, unless the clause carries an external fact with evidence (AGENTS.md's
routing test 0), in which case reclassify as a declaration. A why-clause stays
only when the why changes what the reader does.

## Cross-document checks (after the per-clause pass)

- **Duplication:** the same fact or rule stated in two files. Name both, name
  the deeper layer, recommend keeping only that one.
- **Contradiction:** two files that disagree. Name both, and which the code
  agrees with.
- **Coverage of AGENTS.md's own meta-rules:** AGENTS.md sets rules for docs
  (read-trigger opener, named reader, 80-word line cap, no annotated file
  trees, no status notes, "never kept" list). Check every audited doc against
  every one of them.
- **Self-consistency:** does AGENTS.md obey its own routing tests and layer
  table? Apply them to AGENTS.md as strictly as to any other file.

## Output

Per file, per section, a table:

| Line(s) | Kind | Verdict | Reason (one sentence) | Proposed change |

Verdicts: `keep`, `delete`, `rewrite` (give the text), `move → <file>`,
`fix mechanism → delete` (name it), `fix code → delete` (name the sites),
`false → <evidence>`, `unverifiable`, `contradicts <file>`.

One verdict per clause, and no hedged alternatives — never "delete, or narrow
to X if the maintainer prefers". If two verdicts seem possible, the tests
above decide, and when they genuinely tie the verdict is `delete`; that is
AGENTS.md's own rule and it applies to AGENTS.md. Do not soften a verdict
because the rule is well-written, recently added, or was violated somewhere.

After each file's tables: the list of code defects, dead mechanisms, and
violations in other files the audit surfaced incidentally, each with its
location, since those become issues or PRs rather than doc edits. Then at
most five sentences on the file as a whole: does it still earn its slot in
docs/README.md, and is its named reader the reader it actually serves.

Do not edit any file.

Question 1 has to be judged by a model at least as capable as the one that
will read the docs, or the audit keeps whatever the judge finds hard. Run each
file in its own subagent so it gets a full context.
