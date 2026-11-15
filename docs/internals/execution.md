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

## Cell ops (core/cell_engine.lua)

Boundaries via cursor-position searches (find_cell_boundaries line 29:
`"bcnW"` backward marker + `"nW"` next), insert/split/merge/toggle = pure
buffer edits around the configured marker (line 9-27: `get_cell_pattern` is
the Lua-pattern form, `vim_search_pattern` the Vim-regex form — never
hardcode `# %%`). run_cell (line 211): flag → boundaries →
`vim.fn.MoltenEvaluateRange(s, e)` with visual-mark fallback.

## Run-all + completion polling (keymaps.lua) — THE FRAGILE PART

`<leader>jR` (line 484) executes cells sequentially: navigate →
`evaluate_percent_cell` (line 333) → `wait_for_cell_completion` (line 232)
polls every 150ms (line 25) up to 30s (line 26), detecting completion by
**scraping Molten's virtual text for `Out[N]: ✓ Done`**
(`extract_completed_output_num`, line 180) — the highest completed `Out[N]`
must strictly increase (`get_highest_completed_output`, line 192).
Markdown cells are skipped (line 542); cursor moves run under
`with_suppressed_events` (line 320).

Namespace lookup (`get_molten_namespace`, line 105) must match
**`"molten-extmarks"` exactly** — the block comment at lines 41-55 is law:
`^molten` prefix matching nondeterministically hits `molten-highlights`
and causes 30s timeouts (pre-91adb5c). Cached; invalidated on BufEnter
(line 66-82) except while a notebook reload is in flight (recursion
guard check).

## UI (ui.lua)

`number_cells` (line 88): virt-text `[Cell N: code|markdown]` in
`pyworks_cell_numbers` ns, red/green by `M.executed_cells[buf][N]`
(mark_cell_executed line 50 / cleared line 61), debounced 150ms renumber on
TextChanged (setup_buffer line 245). Folding (lines 126-155): `foldexpr`
`>1` at each marker. Float windows: `create_floating_window` (line 371) —
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
