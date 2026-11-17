# pyworks.nvim — Language-Model Session Memory (LMS)

> **Purpose**: context bootstrap for a fresh AI chat with zero history.
> **Protocol**: read this file FIRST; update the STATE and ACTIVE THREADS
> sections BEFORE ending any session that changed something meaningful.
> Keep it lean — prune stale entries, date everything, link don't inline.

Last updated: 2026-11-16

## What this project is

Neovim plugin (Lua) for zero-config Python notebook work: venv management
(uv/pip), import-based package detection + installation, `.ipynb` editing via
jupytext CLI, cell execution through Molten + image.nvim. POSIX-only,
Neovim ≥ 0.10. Entry points: `plugin/pyworks.lua` (autocmds) and
`lua/pyworks/init.lua` (setup/commands). Full module map: `AGENTS.md`.

## Current state (2026-11-16)

- **v0.4.0 full-review remediation sweep COMPLETE** on branch `lspcleanup`
  (commits `f592b02..eb44800`, stacked on the F1-F6 work; nothing pushed).
  17 slices: atomic .ipynb save; reload safety (`!`-forced); run-all guard +
  per-iteration revalidation; installed-packages cache fix (pattern
  invalidation + per-project keys); dead-code deletion (check_compatibility,
  wrap, PERSISTENT_JUPYTEXT, dead gates); package-name validation on every
  exec path (+ pip option guard); typosquat lexicographic tie-break;
  uv-aware jupytext install; md_view window lifecycle + no fold churn;
  cell-model memoization (818ms→30ms fold pass); kernels + packages chain
  fully async (UI never blocks on probes); stderr surfacing + bounded
  `:wait()` everywhere; `packages.sync_scope` config (Colab-style
  per-project missing packages); `<leader>jm` format key (jfm alias);
  support-module polish; commands into `setup()`; version 0.4.0 + upstream
  dep refs; docs refreshed.
- Gates: container `unit` ALL green (~380 tests), `scenarios` 17/17,
  `e2e` 7/9 — the 2 red steps remain the KNOWN-UPSTREAM Molten bug
  (thread #1). stylua clean; selene left to CI.
- Two NEW gotchas added to AGENTS.md from this sweep: LuaJIT `(...)?`
  pattern quirk; locals-must-precede-callers (the latter was CAUGHT BY THE
  E2E SMOKE as a real nil-call on the file-open path — keep that run honest).
- Everything about running/testing: `test/README.md` +
  `test/ENVIRONMENT_PLAN.md` (design, findings, security posture).

## Decisions (dated, with rationale pointers)

- **2026-11-16** — **v0.4.0 remediation sweep adopted**: every HIGH/MEDIUM/
  LOW finding from the fresh full review got its own slice+commit+tests
  (17 commits); no backlog left. Key calls: version canonicalized DOWN to
  0.4.0 (next-minor scheme, not pyproject's stray 1.0.0); deps point at
  upstream molten/image (2026-11-15 decision finally applied to
  lazy.lua/README/doc); `packages.sync_scope = "project"` default for
  Colab-like per-project missing packages; `:PyworksAdd`-style option
  smuggling (`--index-url`) is a charset-validation concern, not shell
  injection (array argv).
- **2026-11-16** — **Model A "Folded Notebook" adopted** after S5/S9
  investigation proved jupytext percent CANONICALLY comments markdown cells
  and `pythonComment` makes syntax-region md highlighting dead on real
  buffers. Doctrine: percent script IS the buffer; notebook feel from
  presentation chrome (folds, matchadd concealment, virt text); **single
  buffer** (no scratch/split editors); md UX = inline concealment. The S10–
  S12 patches restructured into the **F1–F6 foundation refactor** — brief,
  verified facts, acceptance criteria, slice checklist:
  **`docs/UX_MODEL_A_REFACTOR.md`**. markdown_hl.lua (S5) is superseded;
  F5 removes it. Next session executes F1.
- **2026-11-16** — `notebooks.lsp` default = `"silence"`: filter
  publishDiagnostics inside markdown regions rather than detach; keeps
  completion, kills the cascade. Region = content lines only (markers stay
  python). Detach implemented via LspAttach + `client:detach_buffer`
  (0.11) / `vim.lsp.buf_detach_client` (0.10). Flow doc:
  `docs/internals/notebooks.md` ("LSP & markdown ergonomics"). DONE in
  F4: the region source is now `core/cell_model.lua` (`markdown_regions`).

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
   `shell` session (headless may be the differentiator). **7/9 is the
   baseline — any run-all/polling change must keep exactly that.**
2. **Push + PR for `lspcleanup`**: F1-F6 + the v0.4.0 sweep are all local.
   No PRs/pushes until the user asks.
3. **Interactive eyeball of F6 concealment** on the user's real config:
   cursor motion through the hidden prefix & insert-boundary UX cannot be
   asserted automatically (spike finding #1c); tweak `concealcursor`/scope
   or flip `md_conceal` default based on that report.
4. **Warm cache before container runs on a cold sandbox** (`warm` is the
   only network-privileged step). Never mount host `$HOME`.

## Where things live

| Need                                   | Look at                                                         |
| -------------------------------------- | --------------------------------------------------------------- |
| Commands/style/architecture for agents | `AGENTS.md`                                                     |
| Run the tests                          | `./test/container.sh --help`, `test/README.md`                  |
| Why the env looks like this + findings | `test/ENVIRONMENT_PLAN.md`                                      |
| Model A refactor brief + F1–F6 checklist | `docs/UX_MODEL_A_REFACTOR.md`                                 |
| Vim help (user-facing)                 | `doc/pyworks.txt` (`:help pyworks`)                             |
| User-visible change notes              | `CHANGELOG.md` under `[Unreleased]`                             |
| Scenario fixtures                      | `test/create_test_scenarios.sh` (auto-regenerated in-container) |

## Etiquette for updating this file

- Date every state change; delete bullets once their topic ships or dies.
- Never record secrets/tokens here.
- If a bullet needs more than ~4 lines, move it to its topical doc and link.
- Behavior/flow changes: update the matching `docs/internals/<flow>.md` in
  the same session (anchors + invariants must not rot).
