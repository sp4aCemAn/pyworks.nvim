# Notebooks: .ipynb round-trip and the recursion problem

pyworks edits Jupyter notebooks as jupytext **percent-format Python** by
intercepting reads/writes — no jupytext.nvim, just the CLI. The tricky part
is that reloading a notebook buffer re-fires autocmds, which historically
recursed into E132 stack overflows.

## Conversion core (notebook/jupytext.lua)

- CLI discovery: `find_jupytext_cli` (line 132) — PATH, then project venv,
  cwd `.venv`, `~/.local/bin`, parent-dir venv; **prepends the found dir to
  `vim.env.PATH`** (line 158-164) so bare `jupytext`/`jupyter` resolve to
  the sandbox/project later (mutating process env — tests rely on this).
- `is_jupytext_installed` (line 19): cached (`jupytext_installed`, TTL 1h):
  PATH check → venv binary → `python -c "import jupytext"` fallback.
  `install_jupytext` (line 85) exists but is effectively unused (jupytext
  ships with essentials now).
- Converters are blocking `vim.system(...):wait()` — read: `--to py:percent
  --output -` (line 173); write: stdin `--to ipynb` (line 196).

## Handlers (setup_notebook_handler, line 321)

| autocmd | behavior |
|---|---|
| BufReadCmd `*.ipynb` | skip if `processing_buffers[buf]`; missing file → error buffer; else `read_notebook` (line 219) |
| BufWriteCmd `*.ipynb` | `write_notebook` (line 287) → converts back, writes raw, clears `modified` |

`read_notebook`: disables swapfile, converts, `nvim_buf_set_lines` +
`filetype=python` + `modified=false`, stashes `b:pyworks_notebook_path`
(used by BufWriteCmd) and `b:pyworks_notebook_loaded`. On conversion failure
→ falls back to read-only JSON view (`filetype=json`) with guidance
notifications. The whole body is pcall'd so `processing_buffers[bufnr]`
(line 15, cleared line 279) never sticks.

## The reload problem & recursion_guard (core/recursion_guard.lua)

The cascade: `BufWinEnter → reload_notebook_buffer → :edit → BufReadCmd →
(filetype/Molten churn) → MoltenTick → ... → E132`.

Guard state machine (module-level `state`, line 18):
- `can_reload(bufnr)` (line 43): global lock? per-buffer lock? debounce 500ms
  (line 14)? depth ≥ 3 (line 15)?
- `begin_reload(bufnr)` (line 99) returns a **release function**; you must
  call it even on error. (Historically it also inflated
  `vim.g.molten_tick_rate` — removed 2026-11; Molten caches that value once
  at init, so the trick was a no-op for live Molten and permanently poisoned
  a not-yet-initialized one. Do not reintroduce.)
- `force_reset` (line 166) + `:PyworksResetReloadGuard` (line 191) =
  emergency recovery; `BufDelete` autocmd (line 32) prevents map leaks.

Entry point: `reload_notebook_buffer` in plugin/pyworks.lua:176 — checks
guard, MoltenDeinit (stale extmarks), ensure handler configured,
`:edit fnameescape(path)`, verify first line isn't `{`, retry once with
`edit!`. Callers:
- `:PyworksReloadNotebook` (plugin/pyworks.lua:234)
- BufWinEnter fallback (line 342): buffer empty-or-JSON after 500ms defer,
  double-checked inside the deferred callback with `b:pyworks_notebook_processing`
- SessionLoadPost (line 258): MoltenDeinit all notebooks synchronously, then
  reload them **sequentially** at 600ms spacing (> debounce 500ms, intentional)

## Notebook creation (commands/create.lua)

`:PyworksNewPythonNotebook` (line 322): filename validation
(traversal/invalid chars, line 31) → `generate_notebook_json` (nbformat 4.5,
8-char random ids, line 171 — `math.randomseed` at line 4) → write file →
`open_and_verify_notebook` (line 226) which does the same "first line is `{`?"
check → `configure_notebook_handler()` + `edit!`. If jupytext is missing it
creates the file but tells the user to `:PyworksSetup`. If jupytext will be
installed later in-session, poll marker every 1s × 30 (VENV_CHECK_*, line 14).

## Invariants

- **Any** code that `:edit`s a notebook buffer goes through
  `recursion_guard` (begin/end, release even on error).
- Never trust buffer name for notebook path: `b:pyworks_notebook_path` is
  the save target set at read.
- Session-restore reloads stay sequential with ≥600ms spacing; parallelizing
  them re-opens the E132 class of bugs.
- Conversion commands are argv lists via `vim.system` — no shell strings.

## Covered by

- `tests/jupytext_spec.lua`, `tests/create_spec.lua`, integration recursion
  guard block, container scenarios (notebook fixtures 21/24/25 open real
  .ipynb through the pipeline), e2e step "converted to percent format" +
  round-trip JSON assertion.
