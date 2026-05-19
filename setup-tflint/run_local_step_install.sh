#!/bin/env bash
#
# Local runner for step_install.sh.
# Spins up a tiny local HTTP server serving a fake "tflint" zip so the step
# can exercise its full download+unzip+verify path without hitting GitHub.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

TEST_DIR=$(mktemp -d)
SERVE_DIR=$(mktemp -d)
INSTALL_DIR="${TEST_DIR}/tflint_install"
mkdir -p "${INSTALL_DIR}"

# Build a minimal zip containing a fake "tflint" executable
echo '#!/bin/sh' > "${SERVE_DIR}/tflint"
echo 'echo "tflint-fake-version"' >> "${SERVE_DIR}/tflint"
chmod +x "${SERVE_DIR}/tflint"
(cd "${SERVE_DIR}" && zip -q "tflint.zip" "tflint")

# Serve it on a random local port via python's stdlib http.server
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
( cd "${SERVE_DIR}" && python3 -m http.server "${PORT}" >/dev/null 2>&1 ) &
SERVER_PID=$!
sleep 0.3
trap 'kill ${SERVER_PID} >/dev/null 2>&1; rm -rf "${TEST_DIR}" "${SERVE_DIR}" "${GITHUB_OUTPUT}"' EXIT

export GITHUB_OUTPUT=$(mktemp)
export GITHUB_ACTION_PATH="${_this_script_dir}"
export input_download_url="http://localhost:${PORT}/tflint.zip"
export input_install_dir="${INSTALL_DIR}"
export input_install_bin_path="${INSTALL_DIR}/tflint"

set -o allexport
source "${_this_script_dir}/step_install.sh"
set +o allexport

echo ""
echo "========================================"
echo "Installed binary:"
echo "========================================"
ls -la "${INSTALL_DIR}"
"${INSTALL_DIR}/tflint"
