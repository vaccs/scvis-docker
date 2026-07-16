#!/bin/bash
# Stop the scvis/vaccs containers. Pass --wipe-db to also delete the MySQL
# volume, --debug to save vaccs's error log to ./vaccs_error.log first.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WIPE_DB=0
DEBUG=0
for arg in "$@"; do
    case "$arg" in
        --wipe-db) WIPE_DB=1 ;;
        --debug) DEBUG=1 ;;
        -h|--help)
            echo "Usage: $0 [--wipe-db] [--debug]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

if [ "$DEBUG" -eq 1 ]; then
    # vc (vaccs_comm/vc) runs with cwd /opt/dynamic_analysis inside the
    # container (see vaccs/entrypoint.sh) and logs runtime errors there as
    # vaccs_error.log - grab it before `down` removes the container.
    if docker cp scvis-vaccs:/opt/dynamic_analysis/vaccs_error.log ./vaccs_error.log 2>/dev/null; then
        echo "Saved vaccs's error log to ./vaccs_error.log"
    else
        echo "No vaccs_error.log to save (container not running, or vaccs hasn't logged an error)"
    fi
fi

if [ "$WIPE_DB" -eq 1 ]; then
    docker compose down -v
else
    docker compose down
fi
