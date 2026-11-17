# Python environment: venvs, package managers, hosts

All venv/package-manager behavior lives in `lua/pyworks/languages/python.lua`
plus path helpers in `utils.lua`. The perennial problem: *which* tool manages
this venv — uv or pip — and does it still exist?

## create_venv — python.lua:238

```
uv available? → uv venv <path>          (preferred, always probed regardless
                                          of config.use_uv — line 247)
        else  → python3 -m venv <path>
60s timeout (VENV_CREATE_TIMEOUT_MS), then cache.invalidate("venv_check")
+ state.set_env_status("python","venv_created")
```

The venv location itself is decided by `utils.get_project_paths`
(detection.md): project `.venv` first; name overridable by
`config.python.preferred_venv_name`.

## venv_uses_uv — three heuristics, in order (python.lua:128)

1. `uv.lock` at project root → uv
2. `pyvenv.cfg` contains `uv = ` or `uv-version = ` lines → uv
3. **no `bin/pip` in the venv AND `uv` on PATH → uv** (hardened v0.4.0:
   "pip missing" alone misclassified a pip venv whose pip was upgraded
   away). Still fails open for broken venvs when uv happens to exist.

`get_package_manager(filepath)` python.lua:165 — decision table:

| venv exists? | uv-created? | uv binary? | result |
|---|---|---|---|
| yes | yes | yes | `uv pip` |
| yes | yes | no | venv pip (usually absent → errors) |
| yes | no | any | **venv's own pip** (deliberate: never uv for pip-venvs) |
| no | — | config.use_uv && uv | `uv` (will create) |
| no | — | — | `pip` |

Command construction goes through `build_pip_command` python.lua:199 —
whitelisted actions only (`VALID_PIP_ACTIONS` line 193), package lists are
appended **as argv elements** (never shell strings).

## essentials — python.lua (fully async)

`install_essentials(filepath)`: guarded per-project by
`state["installing_essentials_<dir>"]` (set for the whole probe+install
window) → create venv if missing → probe each `config.essentials` via
`is_package_installed_async` (sequential async `import X` checks; the SYNC
`is_package_installed` remains for `:checkhealth` only) →
`uv pip install`/`venv/bin/pip install` async → on success mark state +
invalidate `^installed_packages_` (pattern — the old literal key never
matched the real per-project keys). The fire-and-forget
`pip install --upgrade pip` (raced the essentials install on the same
venv) was REMOVED v0.4.0.

Throttling: `ensure_environment` is rate-limited by
`state.should_check("python_env","python",30)` — 30s, per nvim session;
its "environment ready" notice only fires from the probe path when
nothing was missing.

## python3_host_prog

`setup_python_host` python.lua:66 candidate order:
`<project venv>/bin/python3` → `.../bin/python` → `cwd/.venv/...` →
`exepath(python3)` → `exepath(python)`. Sets **both** `vim.b.` and `vim.g.`
when a filepath is given (global last-good wins across buffers; the Molten
rhost uses the global). Tests must not leak `VIRTUAL_ENV` into this path
(test/ENVIRONMENT_PLAN.md).

## Legacy parallel API — utils.lua

`utils.detect_package_manager` (utils.lua:56) is an older, simpler
detector (venv uv → system uv → venv pip → pip). **`python.lua` does NOT
use it**; prefer the python.lua functions for new work and don't "unify"
them casually — their semantics differ (utils checks for `venv/bin/uv`).

## Invariants

- Every subprocess path from this module passes argv **lists** through
  `utils.system_with_timeout` / `utils.async_system_call` with `text = true`
  — never `vim.system` with a shell string.
- Package names reaching `build_pip_command` must have passed
  `packages.validate_package_names` + `filter_typosquats` (packages.md).
- `install_essentials`' state guard is cleared in the vim.system callback
  *and* the failure path (line 344-366) — a leaked flag blocks essentials
  for the session.

## Covered by

- `tests/python_security_spec.lua` (argv injection paths),
  `tests/integration_spec.lua` venv-detection block, container
  `PYWORKS_VENV_FLAVOR=pip` matrix (uv vs pip branches).
