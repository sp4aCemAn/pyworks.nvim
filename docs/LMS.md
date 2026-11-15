# pyworks.nvim — Language-Model Session Memory (LMS)

> **Purpose**: context bootstrap for a fresh AI chat with zero history.
> **Protocol**: read this file FIRST; update the STATE and ACTIVE THREADS
> sections BEFORE ending any session that changed something meaningful.
> Keep it lean — prune stale entries, date everything, link don't inline.

Last updated: 2026-11-15

## What this project is

Neovim plugin (Lua) for zero-config Python notebook work: venv management
(uv/pip), import-based package detection + installation, `.ipynb` editing via
jupytext CLI, cell execution through Molten + image.nvim. POSIX-only,
Neovim ≥ 0.10. Entry points: `plugin/pyworks.lua` (autocmds) and
`lua/pyworks/init.lua` (setup/commands). Full module map: `AGENTS.md`.

## Current state (2026-11-15)

- HEAD `e09e27e` ("cleanup of repo") contains: code review outcomes,
  typosquat security guard, recursion_guard fix, container test env.
- **Uncommitted**: container security hardening (non-root, ro repo,
  no-egress networks) + this docs/ restructure + warm-first documentation.
- Test suite (containerized): `unit` ALL GREEN (~290 tests),
  `scenarios` 17/17, `e2e` 7/9 — the 2 red steps are a KNOWN UPSTREAM
  Molten bug (see below), NOT pyworks regressions.
- Everything about running/testing: `test/README.md` +
  `test/ENVIRONMENT_PLAN.md` (design, findings, security posture).

## Decisions (dated, with rationale pointers)

- **2026-11-14** — Full code review graded the repo B; findings drove the
  subsequent work. Report was chat-only; key items are in AGENTS.md's
  "Known open bugs" list.
- **2026-11-14** — Test env = Docker (host is macOS; podman-compatible via
  `CONTAINER_RT`), repo-local sandbox at `test/.sandbox/` (gitignored).
  Never mount host `$HOME`. Rationale: `test/ENVIRONMENT_PLAN.md`.
- **2026-11-15** — Deps move from `jeryldev/*` forks to upstream
  (`benlubas/molten-nvim`, `3rd/image.nvim`). The test env already uses
  upstream. **`lazy.lua`, README install snippets, and doc/pyworks.txt
  still reference the forks — pending.**
- **2026-11-15** — Typosquat guard: content-derived package names are
  hard-blocked on auto-install paths (`is_typosquat`, normalized
  Levenshtein ≤2 vs curated `popular_packages`); `:PyworksAdd` warns but
  proceeds. `popular_packages` is SECURITY-CRITICAL — see AGENTS.md.
- **2026-11-15** — recursion_guard no longer touches `vim.g.molten_tick_rate`
  (Molten caches it once; the mechanism was a no-op-or-poison). Guard +
  debounce + `is_reloading()` checks are the real E132 protection.
- **2026-11-15** — Security posture for test runs: containers run as host
  uid, `--cap-drop ALL`, `no-new-privileges`, repo READ-ONLY mount, tests on
  an `--internal` network (no egress; loopback intact for kernel zmq).
  **`warm` is the only network-privileged step and MUST run before
  unit/scenarios/e2e on a cold sandbox** (they install nothing; e2e's uv
  fixture install runs `--offline` off the warm-seeded cache).

## Active threads / open issues

1. **KNOWN-UPSTREAM (red e2e steps)**: vanilla Molten receives only the
   first 2–3 iopub messages inside a headless pynvim host; `stream` output
   never arrives. Repro + elimination matrix (ipykernel 6/7, pyzmq 26/27,
   kernel venv contents all exonerated; standalone jupyter_client works) in
   `test/ENVIRONMENT_PLAN.md` findings §4. Next action: upstream issue with
   `test/env/e2e_smoke.lua` as repro. Also verify once in an interactive
   `shell` session (headless may be the differentiator).
2. **Version drift** (AGENTS.md bug #1): init.lua header 3.0.3 vs CHANGELOG
   0.3.0 vs pyproject 1.0.0 vs README FAQ "v3.0.3". Needs one canonical
   scheme + a dedicated commit.
3. **Fork references** in `lazy.lua`/README/doc still point at `jeryldev/*`
   while the decision is upstream (see Decisions 2026-11-15).
4. AGENTS.md known-bugs #2–#5 (`is_pyworks_project` always-true,
   `check_compatibility` version math, blocking kernelspec probes,
   jupytext pip-in-uv-venv) — open, each needs own change + tests.

## Where things live

| Need                                   | Look at                                                         |
| -------------------------------------- | --------------------------------------------------------------- |
| Commands/style/architecture for agents | `AGENTS.md`                                                     |
| Run the tests                          | `./test/container.sh --help`, `test/README.md`                  |
| Why the env looks like this + findings | `test/ENVIRONMENT_PLAN.md`                                      |
| Vim help (user-facing)                 | `doc/pyworks.txt` (`:help pyworks`)                             |
| User-visible change notes              | `CHANGELOG.md` under `[Unreleased]`                             |
| Scenario fixtures                      | `test/create_test_scenarios.sh` (auto-regenerated in-container) |

## Etiquette for updating this file

- Date every state change; delete bullets once their topic ships or dies.
- Never record secrets/tokens here.
- If a bullet needs more than ~4 lines, move it to its topical doc and link.
- Behavior/flow changes: update the matching `docs/internals/<flow>.md` in
  the same session (anchors + invariants must not rot).
