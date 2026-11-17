# Startup & load order

## Two independent entry points

1. **`plugin/pyworks.lua`** — loaded by Neovim the moment the plugin dir is
   on `rtp`, *before* `setup()`. Registers every autocmd unconditionally,
   guarded by `vim.g.loaded_pyworks` (plugin/pyworks.lua:4). Also honors
   `PYWORKS_NO_MOLTEN` emergency env var (plugin/pyworks.lua:10) and defines
   notebook-reload commands/autocmds (see notebooks.md).
2. **`require("pyworks").setup()`** — init.lua:199. Idempotent via
   `vim.g.pyworks_setup_complete` (init.lua:203-206): a second call is a
   silent no-op, and config changes require a restart.

## setup() sequence (order matters)

```
setup(opts)                                init.lua:199
 ├─ set molten globals EARLY               init.lua:209  (before MoltenInit reads them)
 ├─ dependencies.setup(opts)               init.lua:215 → defer 100ms → ensure_dependencies()
 ├─ vim.defer_fn(configure_dependencies)   init.lua:220  ← THE DEFERRED-INIT TRAP
 ├─ global <leader>pi / <ps> keymaps       init.lua:225
 ├─ validate_config(opts)  (warn, don't crash)   init.lua:69
 ├─ config = tbl_deep_extend(default_config, opts)  init.lua
 ├─ cache.configure / notifications.configure / python.configure
 │   / packages.configure / cell_engine.configure / state.init+start_session
 ├─ python.setup_python_host() if unset    init.lua
 ├─ vim.g.pyworks_setup_complete = true    init.lua:213-ish
 ├─ require("pyworks.commands.create")     registers create commands
 └─ Pyworks{Next,Prev,...}Cell commands    (inside setup)
```

`configure_dependencies` (init.lua:122) does three things:
- sets ~12 `vim.g.molten_*` globals (only if `:MoltenInit` exists)
- registers a `MoltenKernelReady` autocmd that runs a pandas width snippet
  via `MoltenEvaluateArgument` +500ms — **races user evaluations**; see
  execution.md §ready-hook (own augroup, re-invocation-safe)
- calls `jupytext.configure_notebook_handler()` (init.lua via
  `notebook/jupytext.lua:390`) — installs `BufReadCmd`/`BufWriteCmd` for
  .ipynb — and optionally `image.setup()`.

## The deferred-init trap (bit us in the container e2e)

`configure_dependencies` runs **100ms after startup** (PLUGIN_LOAD_DELAY_MS,
init.lua:13), not synchronously inside setup(). Anything that opens an
`.ipynb` in that window (a `-c "edit ..."` command, a session-restore race)
sees raw JSON because `BufReadCmd` isn't installed yet. The test harness
works around this by calling `require("pyworks").configure_dependencies({})`
synchronously first (test/env/run_scenarios.lua) — that call is idempotent
(re-registers its own autocmds each time).

## Commands register inside setup() (fixed v0.4.0)

All user commands (`PyworksSetup/Sync/Status/Add/Remove/List/Diagnostics/
Help`, the cell-op commands, `PyworksDebugExtmarks`, create/format
commands) register inside `setup()` — requiring the modules no longer has
registration side effects. `tests/integration_spec.lua` asserts the full
expected command list — update it with any command addition.

## Invariants

- `setup()` must remain safe to call before/after Molten is loadable; the
  molten globals are set both early (init.lua:209) and in
  configure_dependencies (init.lua:132) — keep both in sync (single config
  source: `default_config.molten.virt_text_max_lines`).
- `vim.g.pyworks_setup_complete` short-circuit must stay the first check.
- Dependency checks (dependencies.lua:54) only *report/fix what lazy.nvim
  has*; they never install plugins themselves.

## Covered by

- `tests/init_spec.lua`, `tests/integration_spec.lua` (command registry,
  double-setup, config merge), `./test/container.sh scenarios` (autocmds
  live under real file opens).
