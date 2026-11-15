# docs/

Project documentation hub. (The Vim help tree lives in `doc/` — that's
`:help pyworks`; this directory is for humans and agents.)

| File | Audience | Purpose |
|---|---|---|
| [`LMS.md`](LMS.md) | **new AI chat sessions** | session memory: current state, decisions, active threads. Read first, update before ending a session. |
| [`internals/`](internals/README.md) | **agents modifying code** | how the plugin works: 7 flow docs (startup, detection, environment, packages, notebooks, execution, infrastructure) with `file:line` anchors, per-flow invariants, and test coverage pointers. Start at `internals/README.md`. |
| `../AGENTS.md` | agents/contributors | commands, enforced code style, architecture map, gotchas, known bugs |
| `../CHANGELOG.md` | users | release notes; WIP entries live under `[Unreleased]` |
| `../test/README.md` | contributors | how to run the test suites |
| `../test/ENVIRONMENT_PLAN.md` | contributors | container test-env design, security posture, findings log |

New docs go here as flat files unless a topic outgrows ~200 lines, in
which case it gets a subdirectory.
