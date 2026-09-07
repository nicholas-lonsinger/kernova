---
name: make-verdict
description: Build, test, or lint Kernova and get back only the verdict — counts, compile errors, and failing tests with their messages and source locations — never a raw xcodebuild log. Use for every build, test, or lint run in place of make; run the script as a background shell call and the verdict arrives when it exits.
argument-hint: "[build|test|lint|test-suite <Target/Suite>]"
---

Run the make target named by the arguments through this skill's script. Arguments: $ARGUMENTS

| Ask | Command |
|---|---|
| Full test suite | `.agents/skills/make-verdict/make-verdict.sh test` |
| One suite | `.agents/skills/make-verdict/make-verdict.sh test-suite KernovaTests/VMConfigurationTests` |
| Build only | `.agents/skills/make-verdict/make-verdict.sh build` |
| Lint | `.agents/skills/make-verdict/make-verdict.sh lint` |

From the repository root, run the command exactly as written in the table, as a background shell call — in Claude Code, the Bash tool with `run_in_background`, which has no timeout — then act on the completion notification.

The script's stdout is the verdict. It also writes the same lines to `artifacts/make-verdict/<target>.verdict`, with `<target>` the first argument, on every exit — setup errors included.

The verdict file is removed when a run starts and appears whole when it ends, so its existence is the completion signal: the pickup path when the completion notification never arrives, as when a session ended mid-run, and the thing to wait on when a wait is needed.

A start while a run is in progress is refused with `setup-error reason=already-running` and touches nothing, so nothing needs checking before starting one.

The verdict's last line names one of these tokens:

- `green` — done.
- `test-failed` — each `=== <test>` block carries that failure's `path:line: message`; fix those.
- `build-failed` — the `errors:` lines are the deduplicated compiler errors.
- `no-tests-ran` — the run passed but executed zero tests: the suite spelling matched nothing.
- `lint-failed` — the `errors:` lines are the findings; `make format` fixes the Swift ones.
- `setup-error` — bad usage, or the toolchain or a path is missing; the reason is on the line.

Never run `make build`, `make test`, or `make lint` directly (they stream the whole log), never read the log the verdict names, and never re-run a target to change a filter. A different question about the same run is `.agents/skills/make-verdict/xcresult-report.sh --from-log <log>`, or `--path <bundle>` for a downloaded CI artifact.
