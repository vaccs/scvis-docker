#!/bin/bash
# Runs scvis + vaccs together inside a GitHub Codespace (real x86_64, so
# Pin's ptrace-based instrumentation actually works - see README.md) and
# surfaces the forwarded HTTPS URL. scripts/run.sh execs into this
# automatically on non-x86_64 hosts; run it directly if you want that
# without going through run.sh's arch check.
#
# Usage: scripts/run-in-codespace.sh [--no-browser]
#
# Both services run remotely, so there's no tunnel involved for vaccs_comm's
# protocol - it stays entirely on the Codespace's own Docker network. Only
# the plain-HTTP scvis port gets exposed, via GitHub's own browser-facing
# port forwarding (auto-detected the moment something listens on it - no
# `gh codespace ports forward` needed, which is the raw-TCP mechanism that
# doesn't reliably carry vaccs_comm's protocol; ordinary HTTP through
# GitHub's forwarding proxy is a different, much more reliable path, see
# README.md). "web" mode isn't offered here: GitHub's proxy already
# provides its own HTTPS, so scvis-go's own self-signed TLS would just be
# redundant (and TCP-passthrough "web" mode doesn't compose with an
# HTTP-terminating proxy in front of it anyway).
#
# Requires the gh CLI installed. If it isn't authenticated, missing the
# "codespace" scope, or lacks write access to the target repo,
# scripts/fix-codespace-permissions.sh runs automatically to fix that.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./scripts/lib.sh

OPEN_BROWSER=1
for arg in "$@"; do
    case "$arg" in
        --no-browser) OPEN_BROWSER=0 ;;
        -h|--help)
            echo "Usage: $0 [--no-browser]"
            echo "Runs scvis+vaccs together in a GitHub Codespace, prints the forwarded URL."
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

# ---------------------------------------------------------------------------
# 2. Find an existing Codespace for this repo, or create one.
# ---------------------------------------------------------------------------
echo "== Finding an existing Codespace for $REPO =="
CODESPACE_NAME="$(gh codespace list --repo "$REPO" --json name,state -q '[.[] | select(.state=="Available" or .state=="Shutdown")][0].name' 2>/dev/null || true)"

if [ -z "$CODESPACE_NAME" ] || [ "$CODESPACE_NAME" = "null" ]; then
    echo "No existing Codespace found for $REPO - creating one (first run can take a few minutes)..."

    # `gh codespace create` prompts interactively for a machine type if -m
    # isn't given, which fails outright ("no terminal") in a non-interactive
    # script - so pick one ourselves: the cheapest machine that still meets
    # devcontainer.json's hostRequirements (cpus>=4), falling back to the
    # cheapest available at all if somehow none qualify.
    MACHINE="$(gh api "repos/$REPO/codespaces/machines" --jq '
        [.machines[] | select(.cpus >= 4)] as $eligible
        | if ($eligible | length) > 0 then
            ($eligible | sort_by(.cpus) | .[0].name)
          else
            (.machines | sort_by(.cpus) | .[0].name // empty)
          end
    ' 2>/dev/null || true)"
    if [ -z "$MACHINE" ]; then
        echo "ERROR: couldn't determine an available machine type for $REPO." >&2
        exit 1
    fi
    echo "Using machine type: $MACHINE"

    CODESPACE_NAME="$(gh codespace create --repo "$REPO" --machine "$MACHINE")"
else
    echo "Reusing existing Codespace: $CODESPACE_NAME"
fi

echo "== Waiting for Codespace $CODESPACE_NAME to be reachable =="
# Not a state-polling loop: a reused Codespace can be "Shutdown" (GitHub
# auto-stops idle ones), and nothing here would ever resume it just by
# watching its state - gh codespace ssh is what actually triggers a resume
# (same as connecting via VS Code would), and it blocks appropriately while
# that happens, so just let it do that rather than reimplementing it badly.
CS_READY=0
for _ in $(seq 1 24); do
    if gh codespace ssh -c "$CODESPACE_NAME" -- true >/dev/null 2>&1; then
        CS_READY=1
        break
    fi
    sleep 10
done
if [ "$CS_READY" -ne 1 ]; then
    echo "ERROR: Codespace $CODESPACE_NAME never became reachable over SSH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Pull the latest scvis-docker into the Codespace's own checkout (it may
#    have been created a while ago) and run scripts/run.sh there - always
#    "local" mode (see header comment for why "web" doesn't make sense
#    here). --no-codespace stops it from trying to hand off again (moot on
#    a genuine x86_64 Codespace anyway, but explicit beats implicit).
# ---------------------------------------------------------------------------
echo "== Updating scvis-docker inside the Codespace =="
gh codespace ssh -c "$CODESPACE_NAME" -- \
    'cd "$(find /workspaces -mindepth 1 -maxdepth 1 -type d -not -name ".*" | head -1)" && git pull --ff-only'

echo "== Starting scvis+vaccs inside the Codespace (this can take a while the first time) =="
REMOTE_OUTPUT="$(gh codespace ssh -c "$CODESPACE_NAME" -- \
    'cd "$(find /workspaces -mindepth 1 -maxdepth 1 -type d -not -name ".*" | head -1)" && scripts/run.sh local --no-browser --no-codespace' 2>&1)" \
    || { echo "$REMOTE_OUTPUT" >&2; echo "ERROR: scripts/run.sh failed inside the Codespace." >&2; exit 1; }
echo "$REMOTE_OUTPUT"

REMOTE_PORT="$(echo "$REMOTE_OUTPUT" | sed -n 's/.*Host port: \([0-9]\+\).*/\1/p' | head -1)"
if [ -z "$REMOTE_PORT" ]; then
    echo "ERROR: couldn't determine which port scvis is listening on in the Codespace." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Look up the browser URL GitHub assigned to that port. This is detected
#    automatically as soon as something listens on it - no explicit forward
#    needed (verified: `gh codespace ports` shows it immediately).
# ---------------------------------------------------------------------------
BROWSE_URL="$(gh codespace ports --json sourcePort,browseUrl -c "$CODESPACE_NAME" -q ".[] | select(.sourcePort==${REMOTE_PORT}) | .browseUrl" 2>/dev/null || true)"
if [ -z "$BROWSE_URL" ]; then
    echo "ERROR: GitHub hasn't assigned a forwarding URL for port $REMOTE_PORT yet." >&2
    echo "Try: gh codespace ports -c $CODESPACE_NAME" >&2
    exit 1
fi

echo ""
echo "scvis is up: $BROWSE_URL"
echo "(private by default - opens fine in a browser you're already logged into GitHub with;"
echo " to share it, run: gh codespace ports visibility ${REMOTE_PORT}:public -c $CODESPACE_NAME)"
echo "Default admin login (first run only): ${SEED_ADMIN_NAME:-admin} / ${SEED_ADMIN_PASSWORD:-admin1234}"
echo ""
echo "Logs:                gh codespace ssh -c $CODESPACE_NAME -- docker compose logs -f scvis vaccs"
echo "Stop the Codespace:  gh codespace stop -c $CODESPACE_NAME"
echo ""

if [ "$OPEN_BROWSER" -eq 1 ]; then
    open_browser "$BROWSE_URL"
fi
