#!/bin/bash
# One-command version of the hybrid setup documented in README.md under
# "Running vaccs in a Codespace while scvis stays local": finds or creates a
# GitHub Codespace for this repo, builds/starts vaccs there (real x86_64, no
# Rosetta/QEMU translation for Pin to fight with), tunnels its port back to
# this machine, then builds/starts scvis locally against that tunnel.
#
# Usage: scripts/run-codespace.sh [local|web] [--no-browser]
#   local  (default) - scvis served directly, nginx terminates its TLS
#   web            - nginx TCP-passes-through scvis's own TLS (see README.md)
#
# Requires the gh CLI installed. If it isn't authenticated, missing the
# "codespace" scope, or lacks write access to the target repo,
# scripts/fix-codespace-permissions.sh runs automatically to fix that.
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
            echo "Runs vaccs in a GitHub Codespace, scvis locally against it."
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

echo "== Checking gh CLI =="
if ! have_cmd gh; then
    echo "ERROR: the 'gh' CLI is required. Install it: https://cli.github.com/" >&2
    exit 1
fi

echo "== Checking Docker installation (for the local scvis half) =="
./scripts/install-prereqs.sh

if [ ! -f .env ]; then
    echo "No .env found, creating one from .env.example"
    cp .env.example .env
fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a

# ---------------------------------------------------------------------------
# 1. Identify the repo, then make sure gh is authenticated, has the
#    "codespace" scope, and has write access to it (required to create a
#    Codespace there). If any of that is missing, run
#    scripts/fix-codespace-permissions.sh once to fix it automatically
#    (login, add the scope, or fork the repo if you don't have write access)
#    rather than just failing with instructions.
# ---------------------------------------------------------------------------
determine_repo() {
    if [ -n "${CODESPACE_REPO:-}" ]; then
        echo "$CODESPACE_REPO"
        return 0
    fi
    gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
}

gh_ready() {
    gh auth status >/dev/null 2>&1 || return 1
    gh codespace list >/dev/null 2>&1 || return 1
    [ "$(gh api "repos/$REPO" --jq '.permissions.push // false' 2>/dev/null || echo false)" = "true" ]
}

REPO="$(determine_repo)"
if [ -z "$REPO" ]; then
    echo "ERROR: couldn't determine the GitHub repo from this checkout." >&2
    echo "Set CODESPACE_REPO=owner/repo and re-run." >&2
    exit 1
fi

echo "== Checking gh auth/permissions for $REPO =="
if ! gh_ready; then
    echo "Missing gh auth, the codespace scope, or write access to $REPO - attempting to fix it."
    ./scripts/fix-codespace-permissions.sh "$REPO"

    # fix-codespace-permissions.sh may have forked the repo and appended/
    # updated CODESPACE_REPO in .env - re-read it before re-checking.
    set -a
    # shellcheck disable=SC1091
    source ./.env
    set +a
    REPO="$(determine_repo)"

    if ! gh_ready; then
        echo "ERROR: still missing gh auth/permissions for $REPO after attempting to fix it." >&2
        exit 1
    fi
fi

echo "== Finding an existing Codespace for $REPO =="
CODESPACE_NAME="$(gh codespace list --repo "$REPO" --json name,state -q '[.[] | select(.state=="Available" or .state=="Shutdown")][0].name' 2>/dev/null || true)"

if [ -z "$CODESPACE_NAME" ] || [ "$CODESPACE_NAME" = "null" ]; then
    echo "No existing Codespace found for $REPO - creating one (first run can take a few minutes)..."
    CODESPACE_NAME="$(gh codespace create --repo "$REPO")"
else
    echo "Reusing existing Codespace: $CODESPACE_NAME"
fi

echo "== Waiting for Codespace $CODESPACE_NAME to be available =="
CS_READY=0
for _ in $(seq 1 60); do
    STATE="$(gh codespace list --json name,state -q ".[] | select(.name==\"$CODESPACE_NAME\") | .state" 2>/dev/null || true)"
    if [ "$STATE" = "Available" ]; then
        CS_READY=1
        break
    fi
    sleep 5
done
if [ "$CS_READY" -ne 1 ]; then
    echo "ERROR: Codespace $CODESPACE_NAME never became Available (last state: $STATE)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Start vaccs inside the Codespace and wait for its own healthcheck
#    (vaccs/Dockerfile) to pass, same as it would locally.
# ---------------------------------------------------------------------------
echo "== Starting vaccs inside the Codespace =="
gh codespace ssh -c "$CODESPACE_NAME" -- \
    'cd "$(find /workspaces -mindepth 1 -maxdepth 1 -type d | head -1)" && docker compose up -d --build vaccs'

echo "== Waiting for vaccs to become healthy in the Codespace =="
VACCS_READY=0
for _ in $(seq 1 90); do
    HEALTH="$(gh codespace ssh -c "$CODESPACE_NAME" -- 'docker inspect scvis-vaccs --format "{{.State.Health.Status}}"' 2>/dev/null || true)"
    if [ "$HEALTH" = "healthy" ]; then
        VACCS_READY=1
        break
    fi
    sleep 5
done
if [ "$VACCS_READY" -ne 1 ]; then
    echo "ERROR: vaccs did not become healthy in the Codespace in time." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Tunnel the Codespace's vaccs:3580 to this machine. vaccs speaks a raw
#    custom TCP protocol, not HTTP, so this has to be a real port forward -
#    GitHub's normal browser-facing forwarding only understands HTTP(S).
# ---------------------------------------------------------------------------
echo "== Opening a tunnel to the Codespace's vaccs:3580 =="
gh codespace ports forward 3580:3580 -c "$CODESPACE_NAME" &
TUNNEL_PID=$!
trap 'echo "Closing Codespace tunnel..."; kill "$TUNNEL_PID" 2>/dev/null || true' EXIT

TUNNEL_READY=0
for _ in $(seq 1 30); do
    if port_in_use 3580; then
        TUNNEL_READY=1
        break
    fi
    sleep 1
done
if [ "$TUNNEL_READY" -ne 1 ]; then
    echo "ERROR: tunnel to the Codespace's port 3580 never came up." >&2
    exit 1
fi
echo "Tunnel is up: 127.0.0.1:3580 -> $CODESPACE_NAME:3580"

# ---------------------------------------------------------------------------
# 4. Start scvis locally (--no-deps: don't also build/start a local vaccs),
#    pointed at the tunnel via host.docker.internal (Docker Desktop's DNS
#    name for reaching the Mac host from inside a container).
# ---------------------------------------------------------------------------
export MODE
export VACCS_HOST="host.docker.internal"
export VACCS_PORT="3580"
HOST_PORT="$(find_free_port 8080)"
export HOST_PORT
if [ "$HOST_PORT" != "8080" ]; then
    echo "Port 8080 is in use, using $HOST_PORT instead."
fi

echo "== Mode: $MODE | Host port: $HOST_PORT | vaccs: $CODESPACE_NAME (tunneled) =="
echo "== Starting scvis locally =="
docker compose up -d --build --no-deps scvis

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
    docker compose logs --tail=100 scvis
    exit 1
fi

APP_URL="${SCHEME}://127.0.0.1:${HOST_PORT}/scvis/"
echo ""
echo "scvis is up: $APP_URL"
echo "vaccs is running remotely in Codespace: $CODESPACE_NAME"
if [ "$MODE" = "web" ]; then
    echo "(self-signed dev certificate - your browser will warn about it, same as running scvis-go natively)"
fi
echo "Default admin login (first run only): ${SEED_ADMIN_NAME:-admin} / ${SEED_ADMIN_PASSWORD:-admin1234}"
echo ""
echo "This terminal is holding the Codespace tunnel open - keep it running."
echo "Stop scvis locally:  docker compose stop scvis"
echo "Stop the Codespace:  gh codespace stop -c $CODESPACE_NAME"
echo ""

if [ "$OPEN_BROWSER" -eq 1 ]; then
    open_browser "$APP_URL"
fi

echo "Press Ctrl+C to close the tunnel and exit (scvis and the Codespace keep running)."
wait "$TUNNEL_PID"
