---
name: check
description: Build, test, or lint Kernova and get back only the verdict — counts, compile errors, and failing tests with their messages — instead of a raw xcodebuild log. Use for every build, test, or lint run.
argument-hint: "[build|test|lint] [Target/Suite]"
---

Run `make check` in place of `make build`, `make test`, `make test-suite`, and `make lint`:

| Ask | Command |
|---|---|
| Full test suite | `make check` |
| One suite | `make check SUITE=KernovaTests/VMConfigurationTests` |
| Build only | `make check WHAT=build` |
| Lint | `make check WHAT=lint` |

Run it as a bare background shell command — no pipes, `tail`, `tee`, or watcher loops — and act when the harness reports the exit. From a subagent, run it in the foreground with a generous timeout instead.

The output is the whole answer; read its `check: verdict=<token> …` line (make's own `*** [check] Error` line follows it on a failure and carries nothing):

- `green` — done.
- `test-failed` — each `=== <test>` block above it carries that failure's messages; fix those.
- `build-failed` — the `errors:` lines are the deduplicated compiler errors.
- `no-tests-ran` — the run passed but executed zero tests: the `SUITE=` spelling matched nothing.
- `lint-failed` — the `errors:` lines are the findings; `make format` fixes the Swift ones.
- `setup-error` — the toolchain or a path is missing; the reason is on the line.

Never grep the log it names, never poll the task's output file, and never re-run a target to change a filter. A different question about the same run is `Tools/xcresult-report.sh --from-log <log>`, or `--path <bundle>` for a downloaded CI artifact.
