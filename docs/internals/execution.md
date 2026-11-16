# Execution: kernels, Molten, cell running, completion polling

pyworks is an *orchestration layer over Molten* (benlubas/molten-nvim): it
finds/creates the right Jupyter kernel per project, wires keymaps, and adds
cell UX. The fragile bridge is completion detection — see the contract
below before touching keymaps.lua.

## Kernel acquisition (core/detector.lua)

`get_kernel_for_language(lang, filepath)` (line 252; exported line 452):

```
python + filepath?
  ├─ no → generic path: cached "kernel_list" via get_available_kernels
  │        (line 106: jupyter kernelspec list --json, 10s timeout)
  └─ yes → venv path:
       find_python_in_venv (line 133; POSIX bin/python{,3}, creates venv if
       missing) → find_matching_kernel (line 158: kernelspec argv[1] equal
       or prefixed by the venv path) → else create_kernel_for_project
       (line 201: name = parent_project sanitized to ^[%w_]; requires
       ipykernel IN the venv; runs python -m ipykernel install --user)
```

Kernel names are re-validated `^[%w%-_%.]+$` before ever reaching
`vim.cmd("MoltenInit ...")` (auto_init_molten, line 321).

## auto_init_molten (detector.lua:300)

Guarded by `b:molten_init_attempted` (reset on failure so retries work);
sets `b:molten_initialized = true` **when the MoltenInit command returns**
— NOT when the kernel is ready (kernel boot is async; Molten fires User
`MoltenKernelReady`). Consumers: `<leader>jl` auto-init (keymaps.lua:392),
`cell_engine.run_cell` refuses without the flag (cell_engine.lua:216).

## The ready-hook race (init.lua:144-156)

On `MoltenKernelReady`, pyworks defers 500ms then evaluates a pandas
width snippet through Molten. Cold `import pandas` takes seconds; a user
cell evaluating in that overlap gets its output buffer deleted by Molten's
overlapping-cell cleanup (`run_code → try_delete_overlapping_cells`),
stranded as `* On Hold`. The e2e test waits for the hook's cell to complete
before running the user cell (test/env/e2e_smoke.lua) and documents the
upstream interaction; a plugin-side fix (serialize ready-hook evals) is an
open thread (docs/LMS.md).

## Cell ops (core/cell_engine.lua + core/cell_model.lua)

Structure comes from the canonical cell model (F1/F3): `cell_model.for_buffer`
(core/cell_model.lua:54) builds `{index, marker_line, type, start_line,
end_line, marker_text}` cells (preamble = implicit cell 0);
`cell_model.markers` (:99) / `cell_at` (:114) / `is_marker_line` (:132) /
`markdown_regions` (:148). cell_engine keeps its API as call-throughs:
find_cell_boundaries (cell_engine.lua:39) = `cell_at(cursor).start/end`
(nil,nil when empty), count_cells (:47), get_cell_positions (:52),
is_markdown_cell (:73) by TYPE. insert/split/merge/toggle = pure buffer edits
around the configured marker (lines 14-27: `get_cell_pattern` is the
Lua-pattern form, `vim_search_pattern` the Vim-regex form — never hardcode
`# %%`). run_cell (line 194): flag → boundaries →
`vim.fn.MoltenEvaluateRange(s, e)` with visual-mark fallback.

## Run-all + completion polling (keymaps.lua) — THE FRAGILE PART

`<leader>jR` (line 445) executes cells sequentially from the cell model:
snapshot `cell_model.markers(bufnr)` → per cell, skip by TYPE (markdown) or
empty range, else `MoltenEvaluateRange(cell.start_line, cell.end_line)` (the
model's exact content range) → `wait_for_cell_completion` (line 232) polls
every 150ms (line 25) up to 30s (line 26), detecting completion by
**scraping Molten's virtual text for `Out[N]: ✓ Done`**
(`extract_completed_output_num`, line 180) — the highest completed `Out[N]`
must strictly increase (`get_highest_completed_output`, line 192).
Pre-F3 this navigated with cursor-relative searches (`"bnW"` without `c`):
cursor on a marker found the PREVIOUS marker, double-executing adjacent
cells — the model ranges made that class impossible (regression test:
keymaps_spec "run-all via cell model"). Cursor moves run under
`with_suppressed_events` (line 317).

Namespace lookup (`get_molten_namespace`, line 105) must match
**`"molten-extmarks"` exactly** — the block comment at lines 41-55 is law:
`^molten` prefix matching nondeterministically hits `molten-highlights`
and causes 30s timeouts (pre-91adb5c). Cached; invalidated on BufEnter
(line 66-82) except while a notebook reload is in flight (recursion
guard check).

## UI (ui.lua)

`number_cells` (line 79): virt-text `[Cell N: code|markdown]` in
`pyworks_cell_numbers` ns from `cell_model.markers` (F3), red/green by
`M.executed_cells[buf][N]` (mark_cell_executed line 50 / cleared line 61),
debounced 150ms renumber on TextChanged (setup_buffer line 225). Folding:
`cell_fold_expr` (line 128) starts a fold at each marker via
`cell_model.is_marker_line`, `cell_fold_text` (:138) labels folds from the
model. Float windows: `create_floating_window` (line 351) —
`q`/`<Esc>`/WinLeave close it.

## Molten dependency surface

`dependencies.lua` detects the image backend (line 10: kitty/ghostty/
wezterm/iterm→kitty protocol, X11→ueberzug, tmux/unknown→kitty+warning)
and drives Molten's remote-plugin registration (`register_molten` line 214
→ `UpdateRemotePlugins` once per session, requires pynvim in
`g:python3_host_prog`). Molten is a *remote* plugin: its
`exists(":MoltenInit")` check (not a Lua require) is the availability test
everywhere.

## Invariants

- The `Out[N]: ✓ Done` string + `molten-extmarks` name are an **unwritten
  API contract with Molten**. Any Molten rendering change breaks run-all and
  cell-status colors. The e2e smoke test is the tripwire — keep it honest.
- Never `vim.g.molten_*` mutation after Molten's host initialized its
  options (cached at first `:MoltenInit`); use `MoltenUpdateOption`.
- `b:molten_initialized` means "command accepted", not "kernel up".

## Covered by

- `tests/keymaps_spec.lua` (pure helpers via `M._*` exports),
  `tests/cell_engine_spec.lua`, `tests/ui_spec.lua`; live: `./test/container.sh
  e2e` (kernel provisioning → run → polling; currently partially red due to
  the known-upstream stream bug — see test/ENVIRONMENT_PLAN.md findings §4).
