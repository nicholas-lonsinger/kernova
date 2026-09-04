---
name: make-verdict
description: Build, test, or lint Kernova and get back only the verdict — counts, compile errors, and failing tests with their messages and source locations — instead of a raw xcodebuild log. Use for every build, test, or lint run.
argument-hint: "[build|test|lint|test-suite <Target/Suite>]"
---

Run this skill's script in place of the raw make target, as a bare background shell command — no pipes, `tail`, `tee`, or watcher loops — and act when the harness reports the exit. From a subagent, run it in the foreground with a generous timeout instead.

| Ask | Command |
|---|---|
| Full test suite | `.agents/skills/make-verdict/make-verdict.sh test` |
| One suite | `.agents/skills/make-verdict/make-verdict.sh test-suite KernovaTests/VMConfigurationTests` |
| Build only | `.agents/skills/make-verdict/make-verdict.sh build` |
| Lint | `.agents/skills/make-verdict/make-verdict.sh lint` |

It runs the raw target with the whole stream captured under `artifacts/make-verdict/` and prints only the verdict. Read the `make-verdict: verdict=<token> …` line:

- `green` — done.
- `test-failed` — each `=== <test>` block above it carries that failure's `path:line: message`; fix those.
- `build-failed` — the `errors:` lines are the deduplicated compiler errors.
- `no-tests-ran` — the run passed but executed zero tests: the suite spelling matched nothing.
- `lint-failed` — the `errors:` lines are the findings; `make format` fixes the Swift ones.
- `setup-error` — the toolchain or a path is missing; the reason is on the line.

Never run `make build`, `make test`, or `make lint` directly (they stream the whole log into context), never grep the log the verdict names, never poll the task's output file, and never re-run a target to change a filter. A different question about the same run is `.agents/skills/make-verdict/xcresult-report.sh --from-log <log>`, or `--path <bundle>` for a downloaded CI artifact.
