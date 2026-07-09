#!/bin/bash
# Launch scvis-go (+ its VACCS/Pin analyzer) locally in Docker.
#
# Usage: scripts/run.sh [local|web] [--no-browser]
#   local  (default) - app is reachable directly on the host port
#   web            - nginx TCP-passes-through to the app (it always
#                    terminates its own TLS, see README.md)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./scripts/lib.sh

MODE="local"
OPEN_BROWSER=1
for arg in "$@"; do
    case "$arg" in
        local|web) MODE="$arg" ;;
        --no-browser) OPEN_BROWSER=0 ;;
        -h|--help)
            echo "Usage: $0 [local|web] [--no-browser]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

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

echo "== Waiting for scvis to become healthy =="
HEALTH_URL="https://127.0.0.1:${HOST_PORT}/scvis/"
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

APP_URL="https://127.0.0.1:${HOST_PORT}/scvis/"
echo ""
echo "scvis is up: $APP_URL"
echo "(self-signed dev certificate - your browser will warn about it, same as running scvis-go natively)"
echo "Default admin login (first run only): ${SEED_ADMIN_NAME:-admin} / ${SEED_ADMIN_PASSWORD:-admin1234}"
echo "Logs:   docker compose logs -f scvis vaccs"
echo "Stop:   scripts/stop.sh"
echo ""

if [ "$OPEN_BROWSER" -eq 1 ]; then
    open_browser "$APP_URL"
fi
