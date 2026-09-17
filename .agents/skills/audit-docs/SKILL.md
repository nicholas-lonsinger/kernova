---
name: audit-docs
description: Audit AGENTS.md or a docs/ file clause by clause — verify every declaration against the tree, keep only rules that prevent a silent wrong action a capable model would otherwise take, walk the findings through with the maintainer, and fold each of their decisions back into this skill. Use when asked to review, audit, or prune AGENTS.md, CLAUDE.md, or any file under docs/ for correctness or load-bearing content; it edits no audited file, only itself.
argument-hint: "<file> [<file>...]"
---

Audit the file(s) named by the arguments: $ARGUMENTS

With no argument, audit AGENTS.md, then docs/README.md, then every file
docs/README.md indexes, in its order. Research notes under docs/research/ are
immutable: verify nothing in them and edit nothing, but flag any note a doc
cites whose claim current code contradicts.

## Process

Each file is audited by a subagent on a model at least as capable as the one
that will read the docs — question 1 below is judged by the auditor, and a
weaker judge keeps whatever it finds hard. The subagent gets one file and a
full context. The report goes to a file; the terminal gets the headline.

The review is a walkthrough. Present the headline defects first, then take
them one at a time with the maintainer. Every decision the maintainer makes
is generalized before the next item: restate it as a test, apply it to every
remaining verdict, and write it into this file by restatement into the
section it belongs to — never as an example, a date, or a "learned from"
note. When the walkthrough ends, before anything else, read this whole file
and revise it once more: fold in what the walkthrough showed as a pattern
rather than a single decision, restate any test the decisions bent, and
delete what no longer earns its place. Then re-run the file under the
updated skill, reusing the first run's verified facts and discarding its
verdicts. The second run's proposed text is what gets applied, and the
updated skill lands in the same PR as the edits.

Verdicts fall to one of two owners. The audit decides everything the tests
below decide. A stated preference with no wrong action behind it — the shape
of a PR body, the form of a trailer — is the maintainer's: list those
separately, each with one recommended option, and stop there.

What the audit uncovers beside the docs is acted on, not deferred. A code
defect or a mechanism gap becomes a small PR on a subagent while the review
continues, or a GitHub issue filed on the spot. A large refactor or cleanup
is wanted; "low priority, leave it for whoever touches it next" is not a
verdict. A mechanism the audit proposes — a lint, a hook, a repo setting —
is explained before it merges: what it does, where it is called from, and
how it behaves at the edges, in plain terms.

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
  "Principles", the surviving subsystem docs).
- **Pointer** — a link or "read X when Y".
- **Filler** — none of the above (onboarding prose, motivation, restating
  another layer).

## Tests by kind

### Declarations — verify, then ask whether it needs stating

Check every declaration against the current tree, not against another doc:
grep, read the code, read the xcconfig/pbxproj, run `make help`, run `gh api`
for repo settings, fetch the vendor doc for a vendor claim. Report each as
**true**, **false** (with the evidence), or **unverifiable** (say what would
verify it). A grep that matches one line undercounts multi-line declarations;
give the grep rather than the number.

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
   `fix mechanism → delete`, naming the mechanism; the maintainer flips a
   repo setting on the spot. If the rule exists because the tree is
   inconsistent and the rule picks one side, the tree is the defect:
   `fix code → delete`. What survives this question is the failure that looks
   like success — the poll loop that passes locally and flakes in CI, the log
   filter that drops records while the capture looks complete, the pick site
   that works until relaunch.
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

A rule that carves out an exception — two logger types, two transport types
kept plain — is judged with its exception: the audit states why the
exception is structural rather than preferred, and what change would dissolve
it. An exception with no structural reason is a defect to dissolve, and one
with a reason gets its removal path named.

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
  A worked case is a symbol whose header carries the rule, never a doc
  section that restates the principle; a citation that lands on a
  restatement is repointed at the symbol.
- Can the platform implement it? A principle the API cannot honor is false,
  not aspirational — delete it, and delete with it any "if this is wrong,
  fix it here first" self-instruction, which is filler that did not fire.
- Do two principles contradict without a stated tiebreak? Flag.

### Pointers

Target exists, the anchor resolves, and the read-trigger is accurate. Then the
layer test: a pointer whose target docs/README.md already routes to with the
same trigger is a duplicate, and a pointer to a doc that itself links onward
to the same place is one hop too many.

### Filler

Delete, unless the clause carries an external fact with evidence (AGENTS.md's
routing test 0), in which case reclassify as a declaration. A why-clause stays
only when the why changes what the reader does.

### Runbooks

A runbook describes the procedure the maintainer actually runs, verified
against what is installed and what has shipped — profiles, release history,
the distribution channels in use. A lane the maintainer has not run, or a
step nothing has yet reached, is a plan and is not written; it is written
when it happens.

### Declarations about other products

Evidence about another product — what a competitor ships, which
entitlements its store build carries — is never a code comment. It is a
claim about that product's state as of a date, so it is a dated research
note when it decided something, and otherwise nowhere.

### The file as a whole

An inventory doc is a mirror by construction when the code holds the
inventory — a plist, an enum, an xcconfig, a script's array — and each
entry's reason sits beside it as a comment. Such a doc is deleted; what it
holds that the code does not moves beside the entry it explains.

A doc whose sections each mirror one code-layer header — a script's, an
xcconfig's, a hook's, a Makefile comment — is deleted, not trimmed: mirrored
prose is the prose that drifts, and its reader has the header open. The facts
it holds that nothing else does move into the headers that cite the doc for
them. What survives of such a doc is a map — the pieces that exist and where
each explains itself, a few sentences naming places, never summarizing
behavior — placed in the entry-point doc the reader starts from.

## Mechanisms the audit proposes

A `fix mechanism` verdict names lint, a hook, a CI check, a repo setting, or
a GitHub template: a PR or issue body shape written out in a doc is a
`.github/` template, which the web UI and `gh` present at the point of use.
Two constraints on what gets proposed:

- A tool never silently changes what an author wrote. When a check could
  rewrite or block, prefer the instruction plus a validating check, see how
  the instruction goes, and tighten on evidence.
- A gap in the machinery itself — a layer table that cannot classify a doc,
  a routing test with no answer — is closed in the same pass with a
  property-defined addition, not flagged and left.

## Cross-document checks (after the per-clause pass)

- **Duplication:** the same fact or rule stated in two files. Name both, name
  the deeper layer, recommend keeping only that one.
- **Contradiction:** two files that disagree. Name both, and which the code
  agrees with. When the code follows the file that does not own the subject
  under the layer table, the owner's rule wins and the code is swept to it.
- **Dangling references:** for every section the audit deletes, grep the
  other docs for its anchor and for its name in prose, for any sentence
  describing what the audited file contains, and code comments for the file
  name and for bare `§N` forms. A code comment cites a doc by heading name,
  as a trailing clause after a fact the comment states itself —
  `// Bytes are read only on consume — docs/CLIPBOARD.md, "Pay on consume".`
  — never by section number, which lint cannot resolve and renumbering
  strands.
- **Coverage of the doc rules:** AGENTS.md's "Never kept" list (annotated
  trees, issue-keyed tables, inventories, changelogs, status notes,
  alternatives clauses); `Tools/check-docs.sh` owns the line cap and link
  resolution, so lint reports those. A doc's read-trigger is its
  `docs/README.md` row, and the row must match the file's opener.
- **Self-consistency:** does AGENTS.md obey its own routing tests and layer
  table? Apply them to AGENTS.md as strictly as to any other file.

## Output

The report is written to a file. It opens with the headline defects, then
per file, per section, a table:

| Line(s) | Kind | Verdict | Reason (one sentence) | Proposed change |

Verdicts: `keep`, `delete`, `rewrite` (give the text), `move → <file>`,
`fix mechanism → delete` (name it), `fix code → delete` (name the sites),
`false → <evidence>`, `unverifiable`, `contradicts <file>`.

One verdict per clause, and no hedged alternatives — never "delete, or narrow
to X if the maintainer prefers". If two verdicts seem possible, the tests
above decide, and when they genuinely tie the verdict is `delete`; that is
AGENTS.md's own rule and it applies to AGENTS.md. Do not soften a verdict
because the rule is well-written, recently added, or was violated somewhere.

After each section's table, the proposed final text of that section, checked
against the 80-word line cap `Tools/check-docs.sh` enforces. After each
file's tables: the maintainer's-call list (preferences, each with one
recommendation); the incidental findings — code defects, mechanism gaps,
violations in other files — each with its location and its triage under
AGENTS.md's categories; the cross-document findings; then at most five
sentences on the file as a whole: does it still earn its slot in
docs/README.md, and is its named reader the reader it actually serves.

Do not edit any audited file.
