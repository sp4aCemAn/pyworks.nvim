# File detection & routing

Everything that happens when a file enters the editor flows through four
autocmds in `plugin/pyworks.lua` plus the detector.

## Autocmd routing table

| Event | Pattern | Location | What it does |
|---|---|---|---|
| BufReadPost, BufNewFile | `*.py` | plugin/pyworks.lua:27 | defer 100ms → `detector.on_file_open(full_path)`; non-Python files gated by `is_pyworks_project` (line 19) |
| BufWritePost | `*.py`, `*.ipynb` | plugin/pyworks.lua:67 | defer 100ms → `detector.rescan_imports` (detector.lua:441) |
| FileType | `python` | plugin/pyworks.lua:85 | per-buffer one-shot (`b:pyworks_filetype_setup_done`): keymaps, UI setup; for `.ipynb` names → `detector.handle_python_notebook` defer 200ms (line 135-161) |
| BufWinEnter | `*.ipynb` | plugin/pyworks.lua:342 | notebook fallback: if buffer empty/raw-JSON → guarded reload (notebooks.md) |
| SessionLoadPost | — | plugin/pyworks.lua:258 | MoltenDeinit all notebooks, then sequential deferred reloads |

Note `*.ipynb` is deliberately NOT in the BufReadPost pattern (line 29):
jupytext's BufReadCmd owns notebook *reading*; the FileType handler owns
notebook *post-processing*.

## detector.on_file_open — the chokepoint (detector.lua:21)

```
on_file_open(path)
 ├─ absolutize path
 ├─ processing lock: state "processing_<path>"  (line 33-38)
 │    └─ cleared by a deferred finally (line 41) even if the handler throws
 ├─ pcall route:  ext == ipynb → handle_notebook (line 81)
 │                ext == py or ft == python → handle_python (line 357)
 └─ errors → notification, flag still cleared
```

`handle_python` (detector.lua:357): `python.setup_python_host()` → compute
project paths → if no venv: WARN + hint + stash `b:pyworks_filepath`,
**return** (never auto-creates on open) → else `python.handle_file()` +
`auto_init_molten()` (detector.lua:300).

`handle_notebook` (detector.lua:81) first checks
`jupytext.ensure_jupytext()` (jupytext.lua:127 → `is_jupytext_installed`
line 19, cached 1h) then delegates to `handle_python_notebook`
(detector.lua:400), which mirrors handle_python with notebook wording.

## Project root resolution (utils.lua)

- `get_project_paths(filepath)` utils.lua:99 — 5-second memoized cache
  (line 128-132), then: project `.venv` → `$VIRTUAL_ENV` → `$CONDA_PREFIX`
  → `<dir>/.venv`. **Never export VIRTUAL_ENV into pyworks' env in tests** —
  the fallback leaks the venv (documented in test/ENVIRONMENT_PLAN.md).
- `find_project_root(start_dir)` utils.lua:194 — walk up checking an
  *ordered marker list* (.venv first, `.git` near-last, utils.lua:195-214);
  fallback: cwd if the dir is under cwd, else the dir itself.
- `detect_project_type` utils.lua:151 — heuristic chain
  manage.py→Django, app.py→(grep Flask/streamlit), main.py→(grep fastapi),
  dvc.yaml, mlflow.yaml, pyproject.toml, setup.py, requirements.txt,
  environment.yml/conda.yaml.
- **Known bug:** `find_project_root` never returns nil, so
  `is_pyworks_project` (plugin/pyworks.lua:19) is always true and the
  "project-only" gates are dead code. Tracked in AGENTS.md known-bugs #2.

## Invariants

- The `processing_<path>` flag must always be cleared (finally pattern,
  detector.lua:41) or that path is blackholed for the session.
- Detection must never block the UI unboundedly: all probes
  (`jupyter kernelspec list`, pip) go through `utils.system_with_timeout`
  (utils.lua:299). Sync-on-UI-thread occurrences are known bug #4.
- The FileType handler is once-per-buffer; anything re-run per enter goes in
  BufWinEnter handlers with the recursion guard (notebooks.md).

## Covered by

- `./test/container.sh scenarios` — 17 fixtures asserting root/type/
  notification per project style (test/env/run_scenarios.lua).
- `tests/detector_spec.lua`, `tests/utils_spec.lua`.
