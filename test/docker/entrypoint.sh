#!/usr/bin/env bash
# pyworks.nvim test container entrypoint.
#
# Idempotent bootstrap on every run, serialized by a lockfile, then exec the
# requested command. First run pays the install cost; later runs skip via
# marker files. See test/ENVIRONMENT_PLAN.md for the design.
set -euo pipefail

SANDBOX="${PYWORKS_SANDBOX:-/sandbox}"
FLAVOR="${PYWORKS_VENV_FLAVOR:-uv}"
VENV="$SANDBOX/venv-$FLAVOR"
NVIM_CONFIG="$SANDBOX/xdg/config"
NVIM_DATA="$SANDBOX/xdg/data"

export XDG_CONFIG_HOME="$NVIM_CONFIG"
export XDG_DATA_HOME="$NVIM_DATA"
export XDG_STATE_HOME="$SANDBOX/xdg/state"
export XDG_CACHE_HOME="$SANDBOX/xdg/cache"
export JUPYTER_DATA_DIR="$SANDBOX/jupyter"
# NOTE: deliberately NOT exporting VIRTUAL_ENV — utils.get_project_paths()
# falls back to it, which would leak the sandbox venv into tests that
# assert "empty dir -> no venv".
export PYWORKS_HOST_PYTHON="$VENV/bin/python"
# Arbitrary-uid runs have no passwd home; keep all dotfiles in the sandbox.
export HOME="$SANDBOX/home"
export UV_CACHE_DIR="$SANDBOX/uv-cache"

# ipykernel<7: Molten 1.9.2 raises KeyError on ipykernel 7 messages
# (execute_input lost the "wait" field), which strands every cell in
# "* On Hold". Revisit when upstream Molten ships a fix.
# pyzmq<27: pyzmq 27 breaks jupyter_client's IOPubThread delivery pattern
# inside the pynvim host (status messages trickle, stream output never
# arrives); raw-socket clients are unaffected. Evidence: test/ENVIRONMENT_PLAN.
PKGS=(pynvim "ipykernel<7" "pyzmq<27" jupyter_client jupytext numpy pandas matplotlib)

mkdir -p "$NVIM_CONFIG" "$NVIM_DATA" "$SANDBOX/xdg/state" "$SANDBOX/xdg/cache" \
	"$SANDBOX/jupyter" "$SANDBOX/results" "$SANDBOX/e2e" "$SANDBOX/home" "$SANDBOX/uv-cache"

# Molten writes kernel connection files to $JUPYTER_DATA_DIR/runtime and
# does NOT create the dir; real setups get it as a side effect of prior
# jupyter use, a hermetic sandbox must pre-create it (else kernel init
# dies with ENOENT).
mkdir -p "$SANDBOX/jupyter/runtime"

# Serialize concurrent cold starts (two `container.sh` runs on a fresh
# sandbox racing on Lazy install). Uses atomic mkdir, NOT flock(2): BSD
# locks hang across Docker-Desktop virtiofs bind mounts on macOS.
# Only bootstrap needs the lock; raw/no-bootstrap runs must neither take
# it nor be blocked by it.
LOCKDIR="$SANDBOX/.bootstrap.lock.d"
release_lock() { rmdir "$LOCKDIR" 2>/dev/null || true; }
acquire_lock() {
	local deadline=$((SECONDS + 120))
	while [ $SECONDS -lt $deadline ]; do
		if mkdir "$LOCKDIR" 2>/dev/null; then
			# Safety net: release on any early error-exit (the success path
			# releases explicitly; an EXIT trap would not fire through exec).
			trap release_lock EXIT
			return 0
		fi
		# Steal locks older than 15 min (holder likely killed mid-bootstrap)
		if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
			rm -rf "$LOCKDIR"
			continue
		fi
		sleep 2
	done
	echo "[pyworks-env] ERROR: bootstrap lock still held after 120s." >&2
	echo "[pyworks-env] on the host: docker ps --filter ancestor=pyworks-nvim-test" >&2
	echo "[pyworks-env] kill stale containers, or rm -rf test/.sandbox/.bootstrap.lock.d to reset." >&2
	exit 1
}

bootstrap() {
	if [ ! -f "$SANDBOX/.lazy-installed" ]; then
		echo "[pyworks-env] installing plugins (lazy sync)..."
		timeout 600 nvim --headless -u /work/pyworks.nvim/test/env/init.lua \
			-c "Lazy! sync" -c "qa!"
		# Lazy! sync can print "Too many rounds of missing plugins" yet exit 0;
		# verify the load-bearing plugins actually exist before marking done.
		for p in plenary.nvim molten-nvim image.nvim lazy.nvim; do
			if [ ! -d "$NVIM_DATA/nvim/lazy/$p" ]; then
				echo "[pyworks-env] ERROR: lazy sync incomplete (missing $p)" >&2
				exit 1
			fi
		done
		touch "$SANDBOX/.lazy-installed"
	fi

	if [ ! -f "$VENV/.venv-done" ]; then
		echo "[pyworks-env] creating $FLAVOR venv at $VENV..."
		rm -rf "$VENV"
		if [ "$FLAVOR" = "uv" ]; then
			uv venv "$VENV" >/dev/null
			uv pip install --python "$VENV/bin/python" "${PKGS[@]}" >/dev/null
		else
			python3 -m venv "$VENV"
			"$VENV/bin/pip" install --quiet --upgrade pip
			"$VENV/bin/pip" install --quiet "${PKGS[@]}"
		fi
		touch "$VENV/.venv-done"
	fi

	# Molten is a remote plugin: it needs a manifest built against the venv
	# that provides pynvim.
	if [ ! -f "$SANDBOX/.rplugin-done" ]; then
		echo "[pyworks-env] registering remote plugins..."
		timeout 300 nvim --headless -u /work/pyworks.nvim/test/env/init.lua \
			-c "let g:python3_host_prog='$VENV/bin/python'" \
			-c "UpdateRemotePlugins" -c "qa!"
		touch "$SANDBOX/.rplugin-done"
	fi

	# A kernelspec pointing at the sandbox venv, for manual shell testing.
	if [ ! -f "$SANDBOX/jupyter/.kernel-done" ]; then
		echo "[pyworks-env] registering pyworks-test kernel..."
		"$VENV/bin/python" -m ipykernel install \
			--name "pyworks-test-$FLAVOR" \
			--display-name "Python (pyworks test $FLAVOR)" >/dev/null
		touch "$SANDBOX/jupyter/.kernel-done"
	fi
}

# --no-bootstrap ("raw" argv[0]) skips all of the above (image smoke tests).
if [ "${1:-}" = "raw" ]; then
	shift
else
	acquire_lock
	bootstrap
	release_lock
fi

# venv/bin first so bare `jupyter`/`jupytext` resolve to the sandbox,
# matching how the plugin discovers CLIs.
PATH="$VENV/bin:$PATH"

# Fresh persisted plugin state per run keeps scenario results deterministic.
rm -f "$NVIM_DATA/nvim/pyworks_state.json"

# The EXIT trap releases the lock just before exec replaces this shell;
# the actual command itself may run concurrently with others.
exec "${@:-bash}"
