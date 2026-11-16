# AGENTS.md

Guidance for AI agents (and humans) working on pyworks.nvim.

## What this is

Neovim plugin (Lua) providing zero-config Python notebook support: venv
management, package detection/installation, `.ipynb` editing via jupytext,
and cell execution through Molten + image.nvim. Requires **Neovim >= 0.10**
(`vim.system()`, `vim.uv`) and targets **POSIX only** (hardcoded
`venv/bin/...` paths; no Windows support).

## Commands

```bash
./run_tests.sh                 # all plenary specs in tests/
./run_tests.sh -f utils_spec   # single spec
./run_tests.sh -v              # verbose
stylua --check lua/ tests/     # format check (CI enforces)
stylua lua/ tests/             # format
selene lua/                    # lint (CI enforces)
```

CI (`.github/workflows/tests.yml`): test job on ubuntu+macOS × nvim
stable+nightly, plus a lint job (stylua + selene). Keep all four green.

## Code style (enforced)

- **Tabs**, 120 columns, double quotes, `call_parentheses = "Always"`,
  sorted requires — all per `.stylua.toml`. Run `stylua` before committing.
- Selene uses `lua51+vim` std; `unused_variable = "allow"` is set, which
  means dead locals will NOT be caught by tooling — remove them manually.
- `vim.validate({...})` on the first line of every public module API
  (mandated since 0.3.0; see CHANGELOG). Optional params get the `true`
  flag, e.g. `vim.validate({ opts = { opts, "table", true } })`.
- Every autocmd and user command gets `desc = ...`.
- Notifications go through `pyworks.core.notifications` (dedup/suppression
  logic) in library code; direct `vim.notify` only in commands/UI surfaces.

## Architecture map

```
plugin/pyworks.lua        loader: autocmds (file detection, keymaps,
                          session restore, notebook reload fallbacks)
lua/pyworks/init.lua      setup(), config validation/merge, user commands
  core/detector.lua       routing entry point: on_file_open → python |
                          notebook; kernel discovery/creation for Molten
  languages/python.lua    venv create (uv or pip), essentials, install/
                          uninstall/list, package manager detection
  core/packages.lua       import extraction, stdlib/custom filtering,
                          import→PyPI name mappings, name validation
  core/cache.lua          TTL cache with LRU-ish eviction (MAX 1000)
  core/state.lua          in-memory + persisted JSON state (atomic write,
                          debounced save); persistent keys: ^persistent_,
                          ^initialized_
  core/notifications.lua  dedup + context-aware notify, fidget progress
  core/error_handler.lua  protected_call, validators, consistent prefix
  core/recursion_guard.lua  guards notebook :edit cascades (E132);
                          begin/end + force_reset + user command
  core/cell_engine.lua    cell boundaries/nav/insert/split/merge/run
  core/cell_model.lua     canonical percent-buffer cell model (Model A F1):
                          cells + cell_at/markers/markdown_regions/for_buffer
  notebook/jupytext.lua   BufReadCmd/BufWriteCmd for .ipynb ⇄ percent format
  notebook/lsp.lua        Notebook LSP modes: silence (publishDiagnostics
                          filter over markdown regions) / detach (LspAttach)
  notebook/percent_md.lua jupytext percent markdown comment/uncomment codec
  keymaps.lua             <leader>j* / <leader>m* maps; run-all via
                          Molten extmark polling
  ui.lua                  cell numbering virt-text, folding, float windows
  dependencies.lua        lazy-nvim dep checks, image backend detection
  diagnostics.lua / health.lua   :PyworksDiagnostics / :checkhealth pyworks
  commands/create.lua     :PyworksNewPython, :PyworksNewPythonNotebook
  commands/format_cell.lua :PyworksFormatMarkdownCell (notebooks.md_formatter)
  utils.lua               project root/paths, system wrappers, safe IO
```

Deep per-flow documentation with `file:line` anchors, invariants, and test
mapping: **`docs/internals/`** (start at `docs/internals/README.md`). Update
the matching flow doc when you change a flow.

Dependency flow: `plugin/ → core/detector → languages/python → core/*`.
`languages/python.lua` ↔ `core/packages.lua` is a cycle, deliberately broken
by the lazy `get_packages()` require inside functions — preserve that
pattern if you touch either module.

## Gotchas (each one has burned us before)

- **Never hardcode `# %%`.** Use `cell_engine.get_cell_pattern()` (Lua
  pattern, e.g. for `line:match`) or `cell_engine.vim_search_pattern()`
  (vim regex, e.g. for `vim.fn.search`). They differ — `vim.pesc` applies
  only to the Lua one. Custom markers (e.g. `# COMMAND ----------`) are a
  supported config.
- **Molten namespace must match `"molten-extmarks"` exactly.** Never use a
  `^molten` prefix match: Lua table iteration order is nondeterministic and
  `molten-highlights` will sometimes win, causing 30s cell timeouts
  (pre-91adb5c bug). The cache in `keymaps.lua` exists because this runs in
  a 150ms polling loop.
- **Any `:edit` of a notebook buffer must go through
  `core/recursion_guard`.** The reload chain
  (`BufWinEnter → :edit → BufReadCmd → MoltenTick`) deadlocks with E132
  otherwise. Get the release function from `begin_reload()` and always call
  it, even on error (see `reload_notebook_buffer` in `plugin/pyworks.lua`).
- **Cell completion is detected by scraping Molten's virtual text** for
  `Out[N]: ✓ Done`. This is fragile by design; the live tripwire is
  `./test/container.sh e2e` (`test/env/e2e_smoke.lua`). Don't "optimize"
  the polling while that run is red — and note its two currently-red steps
  are a KNOWN-UPSTREAM Molten bug, documented in `test/ENVIRONMENT_PLAN.md`.
- **Shell-injection surface:** package names pass
  `packages.validate_package_names` and kernel names pass
  `^[%w%-_%.]+` validation before reaching `vim.cmd`/`vim.system`. Keep
  every new exec path behind a validator.
- **Typosquat/supply-chain surface:** import names derived from file content
  flow into install suggestions. `packages.is_typosquat`
  (`packages.filter_typosquats`) blocks near-miss names (normalized
  Levenshtein ≤2 vs `popular_packages` + the mapping table) on all
  programmatic install paths; only `:PyworksAdd` (explicit user intent)
  warns-and-proceeds. The `popular_packages` list is SECURITY-CRITICAL —
  curate deliberately via review, never let a PR silently shrink it, and
  add any legitimately popular neighbor that false-positives (precedent:
  `httpie` sits 2 edits from `httpx`).
- Prefer `utils.system_with_timeout` / `utils.async_system_call` over raw
  `vim.system` in library code; always pass `text = true`.
- User commands belong in `setup()` or `plugin/pyworks.lua` — note that
  ~10 currently register at `init.lua` module-load time (known wart; when
  moving them, `integration_spec.lua` asserts the full expected command
  list).

## Known open bugs — flag, don't silently "fix"

Found in the 2026-11 code review; they need dedicated changes with their
own tests, not drive-by edits:

1. **Version drift**: `init.lua` header says 3.0.3, CHANGELOG latest is
   0.3.0, `pyproject.toml` says 1.0.0, README FAQ references v3.0.3.
2. `utils.find_project_root()` never returns nil (falls back to
   `start_dir`), so `is_pyworks_project()` in `plugin/pyworks.lua` is
   always true and "project-only" gating is dead code.
3. `python.check_compatibility()` computes `major + minor/10`, so Python
   3.10 becomes `3.1` and miscompares against two-digit thresholds.
4. Sync `jupyter kernelspec list` / pip calls run on the UI thread in
   `detector.lua` and `diagnostics.lua` (blocking up to 10–30s).
5. `jupytext.install_jupytext` uses `venv/bin/pip`, which fails on
   uv-created venvs (no pip present).

## Tests

- Specs live in `tests/*_spec.lua` (plenary/busted style: `describe`/`it`,
  `assert.*`). Harness: `tests/minimal_init.lua`, `./run_tests.sh`.
- `tests/integration_spec.lua` resets globals between tests — follow the
  existing `package.loaded[...] = nil` reset block pattern when adding to
  it, and update its `expected_commands` list when adding any user command.
- Private functions are exposed for tests as `M._name` (see
  `keymaps.lua`); follow that convention instead of re-exporting publicly.
- Containerized test env (built): `./test/container.sh
  unit|scenarios|e2e|shell` — Docker on macOS, podman via `CONTAINER_RT`.
  Security posture: non-root, repo mounted READ-ONLY, internal-only network
  for test runs (see `test/ENVIRONMENT_PLAN.md`); run `warm` before tests
  on a cold sandbox since bootstrap needs egress.
  Scenario fixtures: `test/create_test_scenarios.sh` (auto-run inside the
  container; `PYWORKS_SCENARIOS_DIR` overrides location — keep scenarios
  OUTSIDE the repo so the plugin's own markers don't leak into detection).

## Repo hygiene

- `test/scenarios/`, `notes/`, `.claude/` are gitignored; don't add build
  artifacts or generated `doc/tags` churn to commits.
- `docs/` is tracked and holds human/AI-facing docs: `docs/LMS.md` is the
  session-memory file — READ IT FIRST when starting a fresh context chat,
  and UPDATE ITS STATE SECTION before ending one that changed anything.
- `doc/` (singular) is the Vim help tree loaded by `:help pyworks`; keep it
  tracked and regenerate tags with `:helptags doc/` when topics change.
- Changelog is Keep-a-Changelog format with a migration note per breaking
  change; add an entry under `[Unreleased]` for every user-visible change.
- This repo previously referenced a `CLAUDE.md` in commit messages — it was
  never tracked. `AGENTS.md` (this file) is the single source of truth;
  don't create a competing instruction file.
