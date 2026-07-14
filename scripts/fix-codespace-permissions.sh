#!/bin/bash
# Sets up the gh CLI permissions scripts/run-codespace.sh needs:
#   1. an authenticated gh session
#   2. the "codespace" OAuth scope
#   3. write access to the target repo (GitHub only lets you create a
#      Codespace on a repo you can push to - if you can't, this forks it to
#      your own account instead and points future runs at the fork)
#
# Called automatically by run-codespace.sh when its own checks fail - you
# can also run it directly: scripts/fix-codespace-permissions.sh [owner/repo]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./scripts/lib.sh

if ! have_cmd gh; then
    echo "ERROR: the 'gh' CLI is required. Install it: https://cli.github.com/" >&2
    exit 1
fi

REPO="${1:-${CODESPACE_REPO:-}}"
if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [ -z "$REPO" ]; then
    echo "ERROR: no repo to check/fix permissions for. Pass one: $0 owner/repo" >&2
    exit 1
fi

echo "== Checking gh authentication =="
if ! gh auth status >/dev/null 2>&1; then
    echo "You're not logged in to gh."
    if confirm "Run 'gh auth login' now?"; then
        gh auth login -h github.com
    else
        echo "ERROR: gh auth login is required." >&2
        exit 1
    fi
fi

echo "== Checking the 'codespace' OAuth scope =="
if ! gh codespace list >/dev/null 2>&1; then
    echo "Your gh credentials are missing the 'codespace' scope."
    if confirm "Run 'gh auth refresh -h github.com -s codespace' now? (opens a browser)"; then
        gh auth refresh -h github.com -s codespace
    else
        echo "ERROR: the 'codespace' scope is required." >&2
        exit 1
    fi
    if ! gh codespace list >/dev/null 2>&1; then
        echo "ERROR: still missing the 'codespace' scope after refreshing." >&2
        echo "Make sure you approved the scope in the browser, then re-run this script." >&2
        exit 1
    fi
fi

echo "== Checking write access to $REPO (required to create a Codespace on it) =="
CAN_PUSH="$(gh api "repos/$REPO" --jq '.permissions.push // false' 2>/dev/null || echo false)"
if [ "$CAN_PUSH" != "true" ]; then
    echo "You don't have write access to $REPO, so GitHub won't let you create a Codespace on it directly."
    if confirm "Fork $REPO to your own account and use that instead?"; then
        # gh repo fork has no --json/-q output, so the resulting slug is
        # computed rather than parsed: GitHub always forks to <your
        # login>/<same repo name> unless --fork-name/--org override that,
        # neither of which we use. --clone=false --remote=false so this only
        # touches GitHub, not your local git remotes.
        gh repo fork "$REPO" --clone=false --remote=false >/dev/null
        FORK_OWNER="$(gh api user --jq .login)"
        FORK="${FORK_OWNER}/${REPO##*/}"
        echo "Forked to $FORK."

        if [ -f .env ] && grep -q '^CODESPACE_REPO=' .env; then
            sed -i.bak "s#^CODESPACE_REPO=.*#CODESPACE_REPO=${FORK}#" .env && rm -f .env.bak
        else
            printf '\nCODESPACE_REPO=%s\n' "$FORK" >> .env
        fi
        echo "Set CODESPACE_REPO=$FORK in .env - future runs will target your fork automatically."
    else
        echo "ERROR: without write access to $REPO (or a fork of it), a Codespace can't be created there." >&2
        exit 1
    fi
fi

echo "gh is authenticated, has the codespace scope, and has write access to the target repo."
