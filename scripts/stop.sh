#!/bin/bash
# Stop the scvis/vaccs containers. Pass --wipe-db to also delete the MySQL volume.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "${1:-}" = "--wipe-db" ]; then
    docker compose down -v
else
    docker compose down
fi
