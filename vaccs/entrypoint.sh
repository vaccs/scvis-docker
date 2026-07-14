#!/bin/bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/vaccs/dynamic_analysis.git}"
REPO_REF="${REPO_REF:-master}"
# Must be /opt/dynamic_analysis: dynamic_analysis's own vaccs_comm/vaccs_comm.h
# hardcodes absolute paths (COMPILE_COMMAND, ANALYZE_COMMAND, LOGFILE_DIR)
# under this exact directory - cloning anywhere else silently breaks the
# compile/analyze steps vc shells out to per request.
SRC_DIR="/opt/dynamic_analysis"

log() { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1. Clone (or refresh) dynamic_analysis. Never baked into the image -
#    always fetched fresh from git. Public repo, so plain anonymous HTTPS
#    clone works (no ssh-agent needed). Its .gitmodules still lists a
#    libelfincpp98 submodule, but it's unused now that Pin's own libdwarf
#    covers that - a plain clone (no --recurse-submodules) skips it.
# ---------------------------------------------------------------------------
if [ -d "${SRC_DIR}/.git" ]; then
    log "Refreshing existing checkout of ${REPO_REF}..."
    git -C "${SRC_DIR}" fetch --depth 1 origin "${REPO_REF}"
    git -C "${SRC_DIR}" reset --hard FETCH_HEAD
else
    log "Cloning ${REPO_URL} (${REPO_REF}) into ${SRC_DIR}..."
    rm -rf "${SRC_DIR}"
    git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${SRC_DIR}"
fi

# ---------------------------------------------------------------------------
# 2. Build. `make` builds secure_data, vaccs_util, vaccs_comm (-> vc), and
#    the Pin tool (pin/source/tools/PAS). cppcheck is built the same way the
#    project's own Dockerfile does it, if the source is present.
# ---------------------------------------------------------------------------
log "Building dynamic_analysis (make)..."
(cd "${SRC_DIR}" && make clean || true && make)
log "Build complete."

if [ -d "${SRC_DIR}/cppcheck-2.17.0" ]; then
    log "Building cppcheck..."
    (cd "${SRC_DIR}/cppcheck-2.17.0" && mkdir -p build && cd build \
        && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j"$(nproc)")
    log "cppcheck build complete."
fi

# ---------------------------------------------------------------------------
# 3. Set up the environment dynamic_analysis/bashrc describes, then start
#    the persistent server. vaccs_comm/vc is the actual daemon that
#    binds/listens on 3580 (vaccs_comm/vaccs_comm.c) and spawns vcompile/pas
#    subprocesses per incoming analysis request - NOT run_analysis, which is
#    just a leftover debug stub in the original Dockerfile.
# ---------------------------------------------------------------------------
export VACCS="${SRC_DIR}"
export VPIN="${VACCS}/pin"
export VPAS="${VPIN}/source/tools/PAS"
export VUTIL="${VACCS}/vaccs_util"
export VCPP="${VACCS}/cppcheck-2.17.0"
export PATH="${VPIN}/scripts:${VCPP}/bin:${PATH}"

log "Starting vaccs_comm/vc, listening on 3580..."
cd "${SRC_DIR}"
exec ./vaccs_comm/vc
