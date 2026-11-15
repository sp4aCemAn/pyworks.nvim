#!/usr/bin/env bash
# Host wrapper for the pyworks.nvim container test environment.
#
#   ./test/container.sh build      # only when test/docker/Containerfile changes
#   ./test/container.sh warm       # REQUIRED after build/clean: the ONLY
#                                  # network-privileged step; installs plugins,
#                                  # venvs, kernelspec, and seeds the uv cache
#                                  # that test runs install from offline
#   ./test/container.sh unit       # plenary specs (tests/*_spec.lua)
#   ./test/container.sh scenarios  # automated scenario detection suite
#   ./test/container.sh e2e        # Molten kernel smoke test
#   ./test/container.sh all        # warm + unit + scenarios + e2e
#   ./test/container.sh shell      # interactive container with sandbox nvim
#   ./test/container.sh clean      # delete the persisted sandbox state
#   ./test/container.sh raw <cmd>  # run <cmd> in the container, no bootstrap
#
# NOTE: unit/scenarios/e2e run with NO egress (internal network) and the repo
# mounted read-only; on a cold sandbox they will fail bootstrap — run warm
# first (or use 'all').
#
# Docker on macOS; set CONTAINER_RT=podman on Linux (identical commands).
# NVIM_VERSION=nightly ./test/container.sh build switches the Neovim release.
# PYWORKS_VENV_FLAVOR=pip exercises the non-uv plugin paths.
set -euo pipefail

CONTAINER_RT="${CONTAINER_RT:-docker}"
IMAGE="${PYWORKS_IMAGE:-pyworks-nvim-test}"
NVIM_VERSION="${NVIM_VERSION:-stable}"
FLAVOR="${PYWORKS_VENV_FLAVOR:-uv}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$REPO/test/.sandbox"
RO_SUFFIX=":ro"
RW_SUFFIX=""
if [ "$CONTAINER_RT" = "podman" ]; then RO_SUFFIX=":ro,z"; RW_SUFFIX=":z"; fi

die() {
	echo "container.sh: $*" >&2
	exit 1
}

command -v "$CONTAINER_RT" >/dev/null || die "$CONTAINER_RT not found (set CONTAINER_RT)"
mkdir -p "$SANDBOX"

# Security posture for every container invocation:
#   --user: host uid:gid (bind-mount writes stay owned by you; nothing runs
#           as root even if a squatted package RCEs setup.py)
#   --cap-drop ALL + no-new-privileges: can't regain privileges
#   repo mounted READ-ONLY: a compromised test can't tamper plugin source
#           or .git (the host-execution escalation path)
#   test commands use an --internal network: no egress exfiltration; loopback
#           stays available for kernel zmq. warm/raw keep normal networking.
UIDG="$(id -u):$(id -g)"
SEC_FLAGS=(--user "$UIDG" --cap-drop ALL --security-opt no-new-privileges)

ensure_image() {
	if ! "$CONTAINER_RT" image inspect "$IMAGE" >/dev/null 2>&1; then
		echo "==> image '$IMAGE' missing; building ($CONTAINER_RT, NVIM_VERSION=$NVIM_VERSION)"
		"$CONTAINER_RT" build -f "$REPO/test/docker/Containerfile" --build-arg "NVIM_VERSION=$NVIM_VERSION" -t "$IMAGE" "$REPO/test/docker"
	fi
}

ensure_internal_net() {
	if ! "$CONTAINER_RT" network inspect pyworks-test-internal >/dev/null 2>&1; then
		"$CONTAINER_RT" network create --internal pyworks-test-internal >/dev/null
	fi
}

run() {
	# $1: "open" (default bridge, for bootstrap) | "locked" (internal net)
	local mode="${1:-locked}"; shift
	local netargs=()
	if [ "$mode" = "locked" ]; then
		netargs=(--network pyworks-test-internal)
	fi
	# shellcheck disable=SC2086
	# ${arr[@]+...} guard: macOS bash 3.2 treats empty arrays as unbound
	"$CONTAINER_RT" run --rm "${SEC_FLAGS[@]}" ${netargs[@]+"${netargs[@]}"} \
		-v "$REPO:/work/pyworks.nvim$RO_SUFFIX" \
		-v "$SANDBOX:/sandbox$RW_SUFFIX" \
		-e "PYWORKS_VENV_FLAVOR=$FLAVOR" \
		-e "PYWORKS_USE_UV=${PYWORKS_USE_UV:-1}" \
		-e "PYWORKS_TEST_ESSENTIALS=${PYWORKS_TEST_ESSENTIALS:-}" \
		-e "PYWORKS_TEST_DEBUG=${PYWORKS_TEST_DEBUG:-}" \
		-w /work/pyworks.nvim \
		"$IMAGE" "$@"
}

cmd="${1:-}"
[ -n "$cmd" ] && shift || true

case "$cmd" in
	build)
		"$CONTAINER_RT" build -f "$REPO/test/docker/Containerfile" --build-arg "NVIM_VERSION=$NVIM_VERSION" -t "$IMAGE" "$REPO/test/docker"
		;;
	warm)
		# bootstrap needs egress (lazy clones, pip installs)
		ensure_image
		run open true
		echo "==> sandbox ready (image=$IMAGE, venv flavor=$FLAVOR)"
		;;
	unit)
		ensure_image
		ensure_internal_net
		run locked ./run_tests.sh
		;;
	scenarios)
		ensure_image
		ensure_internal_net
		run locked bash -c 'export PYWORKS_SCENARIOS_DIR=/sandbox/scenarios
			bash test/create_test_scenarios.sh >/dev/null
			rm -f /sandbox/results/scenarios.status
			timeout 600 nvim --headless -u test/env/init.lua -c "luafile test/env/run_scenarios.lua" -c "qa!"
			if [ ! -f /sandbox/results/scenarios.status ]; then
				echo "scenario runner CRASHED before completing (no status marker)" >&2
				exit 2
			fi
			[ "$(cat /sandbox/results/scenarios.status)" = "0" ]'
		;;
	e2e)
		ensure_image
		ensure_internal_net
		# uv installs run --offline: warm must have populated /sandbox/uv-cache
		run locked bash -c 'set -e
			PROJ=/sandbox/e2e/proj
			mkdir -p "$PROJ"
			[ -f "$PROJ/requirements.txt" ] || touch "$PROJ/requirements.txt"
			if [ ! -f "$PROJ/nb.ipynb" ]; then
				cat > "$PROJ/nb.ipynb" <<EOF
{"cells": [{"cell_type": "code", "id": "e2e00001", "metadata": {}, "execution_count": null, "outputs": [], "source": ["print(\\"pyworks-e2e \\" + str(6*7))\\n"]}], "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}, "language_info": {"name": "python", "version": "3.12.0"}}, "nbformat": 4, "nbformat_minor": 5}
EOF
			fi
			if [ ! -f "$PROJ/.venv/.venv-done" ]; then
				rm -rf "$PROJ/.venv"
				uv venv "$PROJ/.venv" >/dev/null
				# Mirror plugin essentials the kernel expects: the
				# MoltenKernelReady hook imports pandas on every kernel start.
				uv pip install --offline --python "$PROJ/.venv/bin/python" "ipykernel<7" "pyzmq<27" jupyter_client numpy pandas >/dev/null
				touch "$PROJ/.venv/.venv-done"
			fi
			rm -f /sandbox/results/e2e.status
			timeout 300 nvim --headless -u test/env/init.lua -c "luafile test/env/e2e_smoke.lua" -c "qa!"
			if [ ! -f /sandbox/results/e2e.status ]; then
				echo "e2e runner CRASHED before completing (no status marker)" >&2
				exit 2
			fi
			[ "$(cat /sandbox/results/e2e.status)" = "0" ]'
		;;
	all)
		"$0" warm && "$0" unit && "$0" scenarios && "$0" e2e
		;;
	shell)
		ensure_image
		# shellcheck disable=SC2086
		"$CONTAINER_RT" run -it --rm "${SEC_FLAGS[@]}" \
			-v "$REPO:/work/pyworks.nvim$RO_SUFFIX" \
			-v "$SANDBOX:/sandbox$RW_SUFFIX" \
			-e "PYWORKS_VENV_FLAVOR=$FLAVOR" \
			-e "UV_CACHE_DIR=/sandbox/uv-cache" \
			-e "HOME=/sandbox/home" \
			-w /work/pyworks.nvim \
			"$IMAGE" bash
		;;
	clean)
		rm -rf "$SANDBOX"
		echo "==> sandbox deleted (image kept)"
		;;
	raw)
		ensure_image
		run open raw "$@"
		;;
	"" | -h | --help)
		sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
		;;
	*)
		die "unknown command: '$cmd' (see: ./test/container.sh --help)"
		;;
esac
