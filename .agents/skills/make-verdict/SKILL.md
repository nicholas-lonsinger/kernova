---
name: make-verdict
description: Build, test, or lint Kernova and get back only the verdict — counts, compile errors, and failing tests with their messages and source locations — never a raw xcodebuild log. Use for every build, test, or lint run in place of make; it runs in its own subagent and returns the verdict when the run finishes.
argument-hint: "[build|test|lint|test-suite <Target/Suite>]"
context: fork
background: true
agent: skill-runner
---

Run the make target named by the arguments through this skill's script and return its verdict. Arguments: $ARGUMENTS

| Ask | Command |
|---|---|
| Full test suite | `.agents/skills/make-verdict/make-verdict.sh test` |
| One suite | `.agents/skills/make-verdict/make-verdict.sh test-suite KernovaTests/VMConfigurationTests` |
| Build only | `.agents/skills/make-verdict/make-verdict.sh build` |
| Lint | `.agents/skills/make-verdict/make-verdict.sh lint` |

From the repository root, run the command exactly as written in the table, in the foreground, with the shell call's timeout at its maximum. The script's stdout is the verdict; it also writes the same lines to `artifacts/make-verdict/<target>.verdict`, with `<target>` the first argument, on every exit — setup errors included.

If the shell call times out before the script exits, the run is still going: do not start the script again, since that would begin a second build. Wait for the verdict file instead, in the foreground: `until [ -f artifacts/make-verdict/<target>.verdict ]; do sleep 10; done`.

If that wait times out too and `pgrep -f make-verdict.sh` finds the script still running, wait again. If the script is gone and the file never appeared, the run was killed with the shell call — run the command once more.

Return `cat artifacts/make-verdict/<target>.verdict` verbatim — every line, nothing added, nothing summarized — followed by one line giving the verdict's meaning from this table:

- `green` — done.
- `test-failed` — each `=== <test>` block carries that failure's `path:line: message`; fix those.
- `build-failed` — the `errors:` lines are the deduplicated compiler errors.
- `no-tests-ran` — the run passed but executed zero tests: the suite spelling matched nothing.
- `lint-failed` — the `errors:` lines are the findings; `make format` fixes the Swift ones.
- `setup-error` — bad usage, or the toolchain or a path is missing; the reason is on the line.

Never run `make build`, `make test`, or `make lint` directly (they stream the whole log), never read the log the verdict names, and never re-run a target to change a filter. A different question about the same run is `.agents/skills/make-verdict/xcresult-report.sh --from-log <log>`, or `--path <bundle>` for a downloaded CI artifact.
