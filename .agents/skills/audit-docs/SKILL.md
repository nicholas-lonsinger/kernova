---
name: audit-docs
description: Audit AGENTS.md, CLAUDE.md, a docs/ file, or the agent's memory for this repository clause by clause — verify every declaration against the tree, keep only what prevents a silent wrong action a capable model would otherwise take, route each survivor to the layer that owns it, walk the findings through with the maintainer, and fold their decisions back into this skill. Use when asked to review, audit, or prune any of those; the audit edits nothing it audits.
argument-hint: "<file>|memory [<file>...]"
---

Audit the file(s) named by the arguments: $ARGUMENTS

With no argument, audit AGENTS.md, then docs/README.md, then every file
docs/README.md indexes, in its order. The argument `memory` audits the
agent's persisted memory for this repository: its index, then every file in
it. Research notes under docs/research/ are immutable: verify nothing in
them and edit nothing, but flag any note a doc cites whose claim current code
contradicts.

## Process

Each file is audited by a subagent on a model at least as capable as the one
that will read the docs — question 1 below is judged by the auditor, and a
weaker judge keeps whatever it finds hard. The subagent gets one file, or a
batch of small files that share a subject, and a full context. The report
goes to a file outside the repository, where nothing commits it; the
terminal gets the headline.

The audit pass edits nothing it audits. The review is a walkthrough: present
the headline defects first and take them one at a time with the maintainer,
then the maintainer's-call list. A verdict the tests decide is not walked
unless the maintainer disputes it. Every decision the maintainer makes
is generalized before the next item: restate it as a test, apply it to every
remaining verdict, and write it into this file by restatement into the
section it belongs to — as the principle, never as the instance that
prompted it, a date, or a "learned from" note. When the walkthrough ends,
read this whole file and revise it once more: fold in what the walkthrough
showed as a pattern, restate any test the decisions bent, and delete what no
longer earns its place. Then re-run the file under the updated skill, reusing
the first run's verified facts — a claim it only inferred is verified now —
and discarding its verdicts. The second run's proposed text is what gets
applied, and the updated skill lands in the same PR as the edits.

Verdicts fall to one of two owners. The audit decides everything the tests
below decide. A stated preference with no wrong action behind it is the
maintainer's: list those separately, each with one recommended option, and
stop there.

What the audit uncovers beside the docs — a code defect, a mechanism gap —
is triaged under AGENTS.md's Review Feedback Handling, and nothing that
clears its severity bar waits for whoever touches the code next: **Fix now**
becomes a small PR on a subagent while the review continues, **Fix later**
an issue filed on the spot. A large refactor or cleanup is a welcome
outcome, never a reason to defer. A mechanism the audit proposes is
explained before it merges: what it does, where it is called from, and how
it behaves at the edges, in plain terms.

Work one section at a time. Within a section, go clause by clause — no
skimming, no sampling. A table row, a list item, and each clause of a compound
sentence gets its own verdict. A table of facts is judged as a whole after its
rows: find every rule that consumes it, and if one sentence is the only
consumer, the table folds into that sentence or goes.

## Classify every clause

Assign exactly one kind before judging it:

- **Declaration** — a claim about the repo, the platform, or a vendor.
- **Rule** — tells the reader to do or not do something.
- **Principle** — steers a judgment call when no rule applies.
- **Pointer** — a link or "read X when Y".
- **Filler** — none of the above (onboarding prose, motivation, restating
  another layer, a doc's instructions about itself).

## Tests by kind

### Declarations — verify, then ask whether it needs stating

Check every declaration against the current tree, not against another doc:
grep, read the code, read the build configuration, run the tools, fetch the
vendor doc for a vendor claim. Report each as **true**, **false** (with the
evidence), or **unverifiable** (say what would verify it). Give the grep
rather than a count, since a count is only as good as the pattern.

A true declaration is still deleted when a reader with the repo derives it in
seconds. A false one is not automatically a rewrite: correct it, then run the
corrected version through the same derivability test and the layer test. Most
corrected declarations belong one layer down, or nowhere.

Third-party material — competitive analysis, what another product does or
ships, research into someone else's software — has no home in the repo or
in an agent's memory. Delete it wherever it appears; what it showed about
Apple's platform stays, stated as that fact.

### Rules — the model's judgment is the baseline

A rule earns its place only by preventing a wrong action that a capable model,
given the codebase and no rule, would take **and would not notice**. Three
questions, in order; the first failure sets the verdict.

1. **Would the model choose wrong?** Name the specific wrong action. A rule
   that fixes a choice the model is competent to make replaces judgment with
   a fixed action, and the verdict is `delete`. "Good practice" and "what we
   do" are not wrong actions. A convention every neighboring file already
   follows is derivable by reading neighbors, so it is not a wrong choice
   either.
2. **Would the wrong action fail silently?** If lint, a compile error, a
   required CI check, a hook, a repo setting, or the first review catches it,
   the rule is a reminder, and reminders are deleted — a loud failure is
   caught even when it comes after an irreversible step, unless that step did
   damage. If the mechanism exists but is not yet wired, the verdict is
   `fix mechanism → delete`, naming the mechanism. If the rule exists because
   the tree is inconsistent and the rule picks one side, the tree is the
   defect: `fix code → delete`. What survives this question is the failure
   that looks like success.
3. **Is it the right rule, in the right place?** Given the wrong action, is
   this the narrowest instruction that prevents it? State the fact that makes
   the model choose right rather than the prohibition — a model told the fact
   chooses right on its own, and the prohibition removes discretion the model
   would exercise well. Drop the method when only the outcome matters; keep
   it only when the method is the non-obvious part. Then apply AGENTS.md's
   layer table: a rule that fires only during one procedure belongs in that
   runbook; one that must fire without a lookup stays in AGENTS.md. A
   destination `///` that already holds its one non-obvious constraint takes
   no second: move or cut one first.

A rule that passes all three is **load-bearing**; say so in one word and move
on.

A rule or a code site that carves out an exception is judged with its
exception: the audit states why the exception is structural rather than
preferred, and what change would dissolve it. An exception with no structural
reason is a defect to dissolve. One with a reason gets that reason stated
where the exception lives — unstated, it reads as a divergence to consolidate
— and its removal path named in the report.

A clause telling the reader a question is settled and not to reopen it is
deleted: AGENTS.md's top rule outranks it, and what survives is the fact that
makes reopening unnecessary.

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
- Does the worked case it cites still exist and still exemplify it? A worked
  case is a symbol whose header carries the rule, never a doc section that
  restates the principle; a citation that lands on a restatement is repointed
  at the symbol.
- Can the platform implement it? A principle the API cannot honor is false,
  not aspirational — delete it.
- Do two principles contradict without a stated tiebreak? Flag.

### Pointers

Target exists, the anchor resolves, and the read-trigger is accurate. Then the
layer test: a pointer whose target docs/README.md already routes to with the
same trigger is a duplicate, and a pointer to a doc that itself links onward
to the same place is one hop too many. A sentence naming a skill as the way
to do a step names the task instead: the skill's description is its
advertisement, and a second one drifts from it.

### Filler

Delete, unless the clause carries an external fact with evidence (AGENTS.md's
routing test 0), in which case reclassify as a declaration. A why-clause stays
only when the why changes what the reader does.

### Memory

A memory file is one section, audited by the same tests, and AGENTS.md's
layer table routes every clause that passes as if newly written — its memory
row included, and often to a mechanism, since a script that reports the
condition a memory warns about deletes the memory. A fact observed through
one agent's tool but stated about the app or the platform holds under any
agent, and a rule that binds work in the repository is not a private
arrangement because it discloses a plan or a stance. Two things differ:

- **Its read-trigger is its `description` and its index line.** Judge each
  as a docs/README.md row: it names the situation in which the reader needs
  the memory, and it matches the body. A file the index omits, or an index
  line whose file is gone, is a dangling pointer.
- **What stays must earn memory.** It is a non-obvious external fact that
  costs real time to rediscover, a preference that could not be guessed, or
  an environmental fact invisible from the tree — judged against a model
  more capable than the auditor, since the auditor is the model most likely
  to have needed it. Where the subject changes release to release, an agent
  harness above all, keep the shape of the failure, not its mechanism. A
  `Why:` that narrates how the memory was learned is filler.

A fact the table sends to an agent's user scope is `move → user scope`,
outside this audit's edits. A moved memory's file and index line are deleted
once the PR carrying its destination merges, never before: an abandoned PR
would take the fact with it.

### Runbooks

A runbook describes the procedure the maintainer actually runs, verified
against evidence that it is run. What has not happened yet is a plan and is
not written; it is written when it happens.

### The file as a whole

A doc that mirrors what the code already holds — an inventory the code keeps
with each entry's reason beside it, or sections that each restate one header
— is deleted, not trimmed: mirrored prose is the prose that drifts, and its
reader has the source open. The facts it holds that nothing else does move
beside what they explain. What survives of such a doc is a map — the pieces
that exist and where each explains itself, a few sentences naming places,
never summarizing behavior — placed in the entry-point doc the reader starts
from.

## Mechanisms the audit proposes

A `fix mechanism` verdict names whatever enforces or presents the rule at the
point of use: lint, a hook, a CI check, a repo setting, a template the
platform shows when the thing is created. Four constraints on what gets
proposed:

- A tool never silently changes what an author wrote. When a check could
  rewrite or block, prefer the instruction plus a validating check, see how
  the instruction goes, and tighten on evidence.
- A mechanism acts only on what its caller owns. One that would quit,
  delete, or rewrite something the maintainer or another session may hold —
  a running app, a VM, a checkout — is a procedure step that stops to ask,
  not a mechanism.
- The observation a mechanism rests on is reproduced before it is built:
  a memory records what one session saw, often through one tool, and the
  mechanism inherits its premise.
- A gap in the machinery itself — a layer table that cannot classify a doc,
  a routing test with no answer — is closed in the same pass with a
  property-defined addition, not flagged and left.

## Cross-document checks (after the per-clause pass)

Run once over every file's report together, not per subagent, against the
default branch as it stands then: a merge since the per-file pass can settle
or moot a verdict, and each such verdict is re-checked.

- **Duplication:** the same fact or rule stated in two files, memory against
  the repo docs included. Name both, name the deeper layer, recommend keeping
  only that one.
- **Contradiction:** two files that disagree. Name both, and which the code
  agrees with. When the code follows the file that does not own the subject
  under the layer table, the owner's rule wins and the code is swept to it.
- **Dangling references:** for every section the audit deletes, grep the
  other docs for its anchor and its name in prose, any sentence describing
  what the audited file contains, and code comments for the file name and
  for section-number forms. A code comment cites a doc by heading name, as a
  trailing clause after a fact the comment states itself, never by section
  number.
- **Coverage of the doc rules:** AGENTS.md's routing tests, including the
  rule that a section mirroring another layer is deleted whole; lint owns
  the line cap and link resolution. A doc's read-trigger is its `docs/README.md`
  row, and the row must match the file's opener.
- **Self-consistency:** does AGENTS.md obey its own routing tests and layer
  table? Apply them to AGENTS.md as strictly as to any other file.

## Output

The report is written to a file. It opens with the headline defects, then
per file, per section, a table:

| Line(s) | Kind | Verdict | Reason (one sentence) | Proposed change |

Verdicts: `keep`, `delete`, `rewrite` (give the text), `move → <file>`,
`fix mechanism → delete` (name it), `fix code → delete` (name the sites),
`false → <evidence>`, `unverifiable`, `contradicts <file>`, and for memory
`move → user scope`.

One verdict per clause, and no hedged alternatives. If two verdicts seem
possible, the tests above decide, and when they genuinely tie the verdict is
`delete`; that is AGENTS.md's own rule and it applies to AGENTS.md. Do not
soften a verdict because the rule is well-written, recently added, or was
violated somewhere.

After each section's table, the proposed final text of that section, checked
against the line cap lint enforces. After each file's tables: the
maintainer's-call list (preferences, each with one recommendation); the
incidental findings — code defects, mechanism gaps, violations in other files
— each with its location and its triage under AGENTS.md's categories; the
cross-document findings; then at most five sentences on the file as a whole:
does it still earn its slot in docs/README.md, and is its named reader the
reader it actually serves.
