# Infrastructure: cache, state, notifications, errors, utils

Small modules with global blast radius — nearly every flow touches them.
Their *quirks* are the stuff of heisenbugs, so they're documented to
surprise level, not feature level.

## core/cache.lua — TTL memo with LRU-ish eviction

- `M.get/M.set/M.invalidate/M.invalidate_pattern/M.stats` (lines 39/94/110/116/133).
- TTLs: `default_ttl` table (line 13) chosen by **prefix match** of the
  lowercased key (`get_ttl`, line 24) — key `venv_check_anything` inherits
  `venv_check`'s 30s; unknown keys default 60s; explicit `ttl` arg wins.
- Eviction at 1000 entries (`MAX_CACHE_SIZE`, line 10): drops oldest 10% by
  timestamp (line 59). Not LRU — recency doesn't refresh timestamps.
- Quirk: `stats()` (line 133) evaluates expiry with `get_ttl(key)` and
  **ignores per-entry `entry.ttl`** — reported expired counts can lie.
- Cache keys in use (grep-able contract): `imports_<path>_<lang>`,
  `installed_packages_<lang>_<path>`, `kernel_list`, `jupytext_installed`,
  `venv_check`.

## core/state.lua — memory + JSON persistence

- Two persistence rules baked in: a key persists to
  `$XDG_DATA/nvim/pyworks_state.json` iff it matches `^persistent_` or
  `^initialized_` (save filter line 47-54, set-hook line 135). Everything
  else is session-memory.
- Writes are **atomic** (tmp + rename, line 47) and **debounced** 500ms
  (line 91) — data written microseconds before quit can be lost; tests must
  not assert on the file immediately.
- Key prefixes centralized in `M.KEYS` (line 7). `initialized_<context>`
  doubles as the notifications first-time ledger, so it survives restarts:
  "first time" means first time *ever*.
- Session helpers: `start_session` (line 181, id = tempname), throttle trio
  `set_last_check/get_last_check/should_check` (lines 161-178, default 300s).

## core/notifications.lua — the decision tree everyone forgets

`M.notify(message, level, options)` (line 74):

```
dedup: identical message within 10s (HISTORY_TTL_SECONDS, line 9) → dropped
       unless options.force
debug_mode → always show, prefixed
options.force|always        → show
options.error               → show, ERROR
options.action_required     → show, WARN
options.first_time          → show iff verbose_first_time
options.progress            → show iff show_progress
otherwise:
   silent_when_ready=true (DEFAULT)  → HIDE
   silent_when_ready=false           → show iff level >= WARN
```

**Consequence: a plain INFO notification is invisible in every default
configuration** — a test that waits for "Run :PyworksSetup ..." (INFO, no
options) waits forever. The scenario suite learned this the hard way
(test/env/run_scenarios.lua header note). Assert on WARN/ERROR/
action_required/first_time messages only.

Progress (lines 121-171): fidget.nvim when present, notify-fallback
otherwise. `notify_first_time` (line 174) marks the `initialized_<ctx>`
state key. Config via setup notifications.* (init.lua defaults).

## core/error_handler.lua — consistent user-facing failures

`protected_call(func, prefix, ...)` (line 13): pcall + strips `file:line:`
and `attempt to` noise from the message + single ERROR notification format
(`[Pyworks] prefix: msg`). Validators return nil (after notifying) rather
than throwing: `validate_filepath` (28), `validate_directory` (54),
`validate_executable` (83), `validate_packages` (97). `show_error_details`
(141) opens a scratch split. Convention: command handlers wrap risky calls
in `protected_call`; library code uses notifications module.

## utils.lua — paths + subprocess wrappers

- System wrappers (see environment.md invariants): `async_system_call`
  (line 256, callback `(success, stdout, stderr, exit_code)`, signal 15/9 →
  timeout msg) and `system_with_timeout` (line 299, blocking with uv-level
  timeout, default 30s).
- Path helpers: `ensure_venv_in_path` (line 42, prepends venv/bin to
  `vim.env.PATH` once — process-global mutation), `better_select` (line 80,
  vim.ui.select + numeric fallback), `safe_file_read/write` (lines 327/351,
  pcall + guaranteed close), `check_python_import` (line 434, validates
  module name against `^[%w_%.]+$` before shelling out),
  `is_plugin_installed` (line 425 — lazy.nvim key lookup; Molten is checked
  under key `"molten-nvim"` wherever it's installed from).
- Project path machinery: detection.md.

## health.lua / diagnostics.lua — two views, different jobs

`:checkhealth pyworks` (health.lua:6) — standard vim.health report:
module loads, deps via `dependencies.check_health` (dependencies.lua:247),
venv/essentials (sync `is_package_installed` probes — slow), host sanity,
cache stats, autocmd presence. `:PyworksDiagnostics` (diagnostics.lua:77) —
human buffer dump (cwd `.venv`-centric; note: doesn't use
`get_project_paths`, intentionally cwd-scoped). Prefer extending health.lua.

## Invariants

- Never bypass the notifications module in library code (dedup + levels are
  a UX contract; direct `vim.notify` only in commands/UI surfaces).
- New persisted state keys must be `^persistent_`/`^initialized_` prefixed
  or they will silently not survive restarts.
- All cache keys must have a deliberate invalidation point (install →
  `installed_packages_python`, save → `imports_...`, setup →
  `venv_check`/`jupytext_installed`).

## Covered by

- `tests/cache_spec.lua`, integration blocks for notifications/state/error
  handling; `tests/utils_spec.lua`.
