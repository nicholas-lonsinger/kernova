---
name: make-verdict
description: Build, test, or lint Kernova and get back only the verdict — counts, compile errors, and failing tests with their messages and source locations — never a raw xcodebuild log. Use for every build, test, or lint run in place of make; run the script as a background shell call and the verdict arrives when it exits.
argument-hint: "[build|build-for-testing|test|test-without-building|test-suite <Target/Suite>|lint]"
---

Run `.agents/skills/make-verdict/make-verdict.sh $ARGUMENTS`; its `--help` lists the targets and defines every verdict token and exit code.
