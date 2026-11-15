# Container Test Environment — Plan (PARKED)

> Status: **PARKED** — design agreed, not implemented.
> Recorded 2026-11-14. Pick this up when automated end-to-end testing becomes a priority.

## Goal

A fully isolated, reproducible environment that can run the plenary specs, the
scenario suite, and real kernel execution without ever touching the host's
`~/.local/share/nvim`, real Jupyter kernels, or `PATH`.

## Runtime

- Host is macOS → **Docker**. Linux users can swap to podman: the wrapper
  script takes a `CONTAINER_RT` env var (default `docker`) and all commands
  are identical. Containerfile stays podman-rootless-friendly (no
  docker-only syntax; `:z` relabel on mounts; nothing privileged).

## Image design

`test/docker/Containerfile`:

- Base: `ubuntu:24.04`. Baked in: git, curl, unzip, python3 + venv, **uv**,
  and a Neovim release tarball.
- `NVIM_VERSION` build arg (`stable` default; `nightly` pinned) so the old
  stable/nightly matrix is still possible later.
- Image contains **tools only** — no plugins, no venvs, no kernels. Those
  live in the bind-mounted sandbox so rebuilds stay rare (only when the
  Containerfile itself changes).

## Sandbox state — `test/.sandbox/` (gitignored, bind-mounted at `/sandbox`)

First-run bootstrap populates it; it persists across container runs, which
locally replaces CI caching. `clean` = `rm -rf test/.sandbox`.

| Path | Contents |
|---|---|
| `xdg/{config,data,state,cache}` | lazy.nvim + pinned plenary / **upstream** BenobioM/molten.nvim + 3rd/image.nvim (forks cut per 2026-11 decision; molten registered under lazy key `molten-nvim`), rplugin manifest from `:UpdateRemotePlugins` |
| `venv/` | pynvim, ipykernel, jupyter_client, jupytext, numpy, pandas, matplotlib |
| `jupyter/` | `JUPYTER_DATA_DIR` — test kernelspecs register here, never in the real home |

All of `XDG_*`, `JUPYTER_*`, and `python3_host_prog` are exported in one
place (the wrapper script) so there is a single source of truth for the
environment.

The repo itself is bind-mounted read-write at `/work/pyworks.nvim` and the
sandbox config loads pyworks straight from that path (lazy `dev = true`
style), so editing `lua/pyworks/**` and relaunching nvim is the entire
inner loop — no reinstall, no rebuild.

## Entrypoint: idempotent auto-sync (no manual bootstrap phase)

Every `container.sh <cmd>` runs the entrypoint first:

1. `nvim --headless '+Lazy! sync' +qa` — installs plugins on run #1
   (~30s, needs network once), then no-ops in ~1s from the persisted mount.
2. Create sandbox venv + register kernelspec — guarded by a marker file.
3. `exec` the requested command.

`warm` exists only as an optional convenience to force step 1–2 now rather
than on the first real run.

**Known caveat:** two commands run concurrently against a *cold* sandbox can
race on Lazy sync. Mitigation: lockfile in `.sandbox` that the entrypoint
waits on. (Alternatively users just run `warm` first — the lockfile is
preferred so the tool stays magic-free.)

## Command surface

```
./test/container.sh build     # only when Containerfile changes
./test/container.sh warm      # optional: force first-run installs now
./test/container.sh unit      # existing plenary specs in tests/
./test/container.sh scenarios # automated scenario suite (below)
./test/container.sh e2e       # kernel smoke test (below)
./test/container.sh all
./test/container.sh shell     # interactive nvim, manual scenario poking
./test/container.sh clean     # rm -rf test/.sandbox
```

## Scenario automation

- Keep `test/create_test_scenarios.sh` as the fixture generator; add a
  per-scenario `expected.json` manifest: `project_type`, venv presence,
  notification substrings, resolved project root (relative).
- New `test/run_scenarios.lua` headless harness: for each generated
  scenario, install a `vim.notify` capture hook writing JSONL to
  `/sandbox/scenario-results.jsonl`, open the fixture file, wait for
  quiescence, assert against the manifest, exit non-zero with a diff-style
  report.
- Run relevant scenarios against **two venv flavors**: real uv venv and real
  pip venv (`PYWORKS_FORCE_PIP=1`), covering the uv-detection branches in
  `languages/python.lua`.

## E2E Molten smoke test (real ipykernel, in container)

`test/e2e/moltentest.lua`: open `21_standalone_notebook/analysis.ipynb` →
wait for `MoltenKernelReady` → run a cell (`<leader>jj` path) → poll the
`molten-extmarks` namespace for `Out[N] ✓` → `:w` → assert the round-tripped
JSON parses and cell sources survived.

This deliberately targets the fragile areas found in the 2026-11 code
review:

- the `Out[N]: ✓ Done` virtual-text polling in `keymaps.lua` (any Molten
  rendering change breaks it — the test is the tripwire),
- the recursion guard under session restore / `BufWinEnter` cascades,
- uv-vs-pip venv detection,
- jupytext read/write round-trip.

## CI — deliberately deferred

Separate future task. Reason: GitHub Actions has no local image layer cache;
each run either rebuilds from scratch (minutes) or requires push/pull of a
prebuilt image to GHCR (registry auth, tag discipline,
`buildx --cache-to/from`). Locally with Docker/podman, layer caching just
works. The existing `.github/workflows/tests.yml` keeps running unchanged
until the new CI story is built.

## Host-side testing during the park

`./run_tests.sh` continues to work on the host exactly as before; nothing in
this plan blocks it.

---

## Status: BUILT (2026-11-14)

Implemented as designed: `test/docker/Containerfile`, `test/docker/entrypoint.sh`,
`test/env/init.lua`, `test/env/run_scenarios.lua`, `test/env/e2e_smoke.lua`,
`test/container.sh`. Sandbox at `test/.sandbox/` (gitignored).

### Bugs this environment caught before any human saw them

1. **`recursion_guard` leaked `safe_tick_rate=999999` into Molten's
   cached options** when Molten initialized inside a notebook-reload window
   (`BufWinEnter` fallback → `begin_reload` → jupytext `vim.system():wait()`
   pumps the event loop → deferred `MoltenInit` reads the inflated
   `vim.g.molten_tick_rate`, which Molten caches forever). Cells stuck at
   `* On Hold`. Fixed in `recursion_guard.lua` (tick-rate manipulation
   removed entirely — it was a no-op for already-initialized Molten and a
   time-bomb otherwise; `is_reloading()` guards + debounce + depth limits do
   the real protection). Regression tests in `integration_spec.lua`.

2. **Container entrypoints assumed `$JUPYTER_DATA_DIR/runtime/` exists.**
   Molten writes kernel connection files there and does not create the dir;
   real desktops have it from prior jupyter use. Entrypoint pre-creates it.

3. **Scenario fixtures were invalid**: `13_dvc_project` never created its
   `src/` dir; every `.ipynb` fixture lacked `nbformat` fields, crashing
   jupytext (`AttributeError: nbformat`). Generator fixed.

4. **Upstream molten cannot stream kernel stdout in headless pynvim host**
   (KNOWN-UPSTREAM, unresolved): with `benlubas/molten-nvim` HEAD +
   jupyter_client 8.10 + ipykernel 6.31/7.x + pyzmq 26/27 (all combos tested
   and pinned), the first 2–3 iopub messages (status/execute_input) land in
   Molten's client, then the queue goes permanently empty inside the
   pynvim-hosted plugin; identical sequences in a standalone script against
   the same kernel spec deliver `stream` + `idle` fine. Kernel side verified
   healthy (direct `print` executes and returns text). The fork's diff vs
   upstream does not contain a relevant iopub patch. Suspect
   `wait_for_ready = run_sync(...)`'s asyncio↔greenlet interaction. **The
   e2e "cell output rendered" step stays RED as the tripwire for this** —
   do not chase it in pyworks; file upstream at benlubas/molten-nvim with
   `test/env/e2e_smoke.lua` + the isolation scripts from this investigation
   as the repro.

5. **Docker-Desktop virtiofs does not implement `flock(2)` across bind
   mounts** (hangs forever). Entrypoint uses atomic-`mkdir` locking instead.

### Declared pins in the environment (and why)

- `ipykernel<7`: Molten 1.9.2-era stack (also avoids `execute_input` schema
  churn); revisit with the upstream stream bug.
- `pyzmq<27`: declared after the jupyter_client thread-delivery change; the
  stream bug persists regardless — kept as the conservative pin.

## Security posture (hardened 2026-11-15)

Every scenario run opens untrusted fixture files, and `pip`/`uv` installs
plus Jupyter kernel code execution mean *arbitrary third-party code runs in
the container by design*. Posture:

| Threat | Control | Verified |
|---|---|---|
| Container escapes to host files | Repo bind-mounted **read-only**; only `test/.sandbox/` is writable | `echo > /work/...` → `Read-only file system` ✓ |
| Tamper with git state (escalation to host execution via hooks/config) | `.git` also read-only | `git config user.email evil` → `could not lock .git/config: Read-only` ✓ |
| Root-uid code execution in container | `--user $(id -u):$(id -g)` + `USER 1000` default; nothing runs as root | `id` → `uid=501` ✓ |
| Privilege escalation | `--cap-drop ALL` + `--security-opt no-new-privileges` | ✓ (all commands) |
| Data exfiltration during tests | `unit`/`scenarios`/`e2e` join an `--internal` network: no egress, loopback intact for kernel zmq | `curl pypi.org` → blocked; `127.0.0.1` socket pair → works ✓ |
| Host config pollution | XDG/JUPYTER/HOME/uv-cache all under `/sandbox`; host `$HOME` never mounted | audit of mounts ✓ |

Rules that follow from this:
- **Run `warm` before test commands on a cold sandbox** — bootstrap needs
  egress (git clones, package downloads); test networks deliberately can't
  fetch anything. `uv` installs in the e2e fixture run `--offline` against
  the seeded cache.
- Tests may not write inside the repo (they already don't: specs use
  `vim.fn.tempname()` + `TMPDIR`, scenarios write to `/sandbox`). Lazy's
  helptag generation is disabled in `test/env/init.lua` so it can't try.
- Postmortem (2026-11-15): repo audited for tampering from the earlier
  root+rw posture — git config/hooks/remotes clean, zero stray files, zero
  root-owned files, doc/tags unchanged. No incident found; hardening is
  prophylactic.
