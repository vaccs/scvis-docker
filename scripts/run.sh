#!/bin/bash
# Launch scvis-go (+ its VACCS/Pin analyzer) locally in Docker.
#
# Usage: scripts/run.sh [local|web] [--no-browser] [--no-codespace]
#   local  (default) - app is reachable directly on the host port
#   web            - nginx TCP-passes-through to the app (it always
#                    terminates its own TLS, see README.md)
#   --no-codespace - skip the non-x86_64 auto-handoff below, stay local
#                    even though vaccs's Pin-based analysis won't work
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./scripts/lib.sh

MODE="local"
OPEN_BROWSER=1
FORCE_LOCAL=0
for arg in "$@"; do
    case "$arg" in
        local|web) MODE="$arg" ;;
        --no-browser) OPEN_BROWSER=0 ;;
        --no-codespace) FORCE_LOCAL=1 ;;
        -h|--help)
            echo "Usage: $0 [local|web] [--no-browser] [--no-codespace]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# vaccs's Pin-based analyzer needs real x86_64 - Pin's ptrace-based
# instrumentation doesn't work under Rosetta/QEMU emulation (see README.md's
# "Pin doesn't run under Rosetta emulation" section). On a non-x86_64 host,
# hand off to a GitHub Codespace (both services run there together, no
# tunnel involved) instead of building a vaccs that can't actually analyze
# anything. --no-codespace bypasses this if you want scvis up locally
# anyway - e.g. to work on scvis-go itself without needing real analysis.
# ---------------------------------------------------------------------------
if [ "$FORCE_LOCAL" -ne 1 ] && [ "$(uname -m)" != "x86_64" ]; then
    if [ "$MODE" = "web" ]; then
        echo "Note: 'web' mode isn't meaningful through Codespaces port forwarding" >&2
        echo "(GitHub's forwarding proxy already provides its own HTTPS) - using local mode there instead." >&2
    fi
    HANDOFF_ARGS=()
    if [ "$OPEN_BROWSER" -eq 0 ]; then
        HANDOFF_ARGS+=(--no-browser)
    fi
    # ${arr[@]+"${arr[@]}"}, not "${arr[@]}": macOS ships bash 3.2, where an
    # empty array under `set -u` trips "unbound variable" on plain "${arr[@]}".
    exec ./scripts/run-in-codespace.sh ${HANDOFF_ARGS[@]+"${HANDOFF_ARGS[@]}"}
fi

echo "== Checking Docker installation =="
./scripts/install-prereqs.sh

if [ ! -f .env ]; then
    echo "No .env found, creating one from .env.example"
    cp .env.example .env
fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a

export MODE
HOST_PORT="$(find_free_port 8080)"
export HOST_PORT
if [ "$HOST_PORT" != "8080" ]; then
    echo "Port 8080 is in use, using $HOST_PORT instead."
fi

# Both scvis-go and dynamic_analysis are public repos, so ssh-agent
# forwarding isn't required - but apply it opportunistically (same as
# eevis-docker/irvis-docker) in case either repo goes private again.
COMPOSE_FILES=(-f docker-compose.yml)
SSH_SOCK="$(find_ssh_agent_sock || true)"
if [ -n "$SSH_SOCK" ]; then
    echo "Forwarding host SSH agent for git clone (found loaded key(s))."
    export SSH_AUTH_SOCK_HOST="$SSH_SOCK"
    COMPOSE_FILES+=(-f docker-compose.ssh-agent.yml)
else
    echo "No usable ssh-agent found on the host."
    echo "Both scvis-go and dynamic_analysis are public, so this is fine as-is."
    echo "If either repo goes private, set its REPO_URL in .env to the SSH form"
    echo "and load a key with ssh-add so it can be forwarded in."
fi

echo "== Mode: $MODE | Host port: $HOST_PORT =="
echo "First run builds the VACCS/Pin analyzer from source under amd64"
echo "emulation plus scvis-go and MySQL - this can take a good while."
docker compose "${COMPOSE_FILES[@]}" up -d --build

if [ "$MODE" = "web" ]; then
    SCHEME="https"
else
    SCHEME="http"
fi

echo "== Waiting for scvis to become healthy =="
HEALTH_URL="${SCHEME}://127.0.0.1:${HOST_PORT}/scvis/"
READY=0
for _ in $(seq 1 180); do
    if curl -kfs "$HEALTH_URL" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 5
done

if [ "$READY" -ne 1 ]; then
    echo "scvis did not become healthy in time. Recent logs:"
    docker compose logs --tail=100
    exit 1
fi

APP_URL="${SCHEME}://127.0.0.1:${HOST_PORT}/scvis/"
echo ""
echo "scvis is up: $APP_URL"
if [ "$MODE" = "web" ]; then
    echo "(self-signed dev certificate - your browser will warn about it, same as running scvis-go natively)"
fi
echo "Default admin login (first run only): ${SEED_ADMIN_NAME:-admin} / ${SEED_ADMIN_PASSWORD:-admin1234}"
echo "Logs:   docker compose logs -f scvis vaccs"
echo "Stop:   scripts/stop.sh"
echo ""

if [ "$OPEN_BROWSER" -eq 1 ]; then
    open_browser "$APP_URL"
fi
