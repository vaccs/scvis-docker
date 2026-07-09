#!/bin/bash
set -euo pipefail

MODE="${MODE:-local}"                       # local | web
CONTAINER_PORT=8080                         # fixed internal port (see Dockerfile EXPOSE);
                                             # the host port it's mapped to is chosen by scripts/run.sh
APP_INTERNAL_PORT="${APP_INTERNAL_PORT:-8081}"  # app port behind nginx, web mode only

REPO_URL="${REPO_URL:-https://github.com/vaccs/scvis-go.git}"
REPO_REF="${REPO_REF:-main}"
SRC_DIR="/opt/scvis-src"
SCHEMA_FILE="/opt/scvis-docker/schema.sql"

DB_NAME="${DB_NAME:-scvis}"
DB_USER="${DB_USER:-scvis}"
DB_PASSWD="${DB_PASSWD:-scvis_dev_password}"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_OWNER="${GITHUB_OWNER:-vaccs}"
GITHUB_REPO="${GITHUB_REPO:-scvis-go}"

VACCS_HOST="${VACCS_HOST:-vaccs}"
VACCS_PORT="${VACCS_PORT:-3580}"

SEED_ADMIN_NAME="${SEED_ADMIN_NAME:-admin}"
SEED_ADMIN_EMAIL="${SEED_ADMIN_EMAIL:-admin@scvis.local}"
SEED_ADMIN_PASSWORD="${SEED_ADMIN_PASSWORD:-admin1234}"

log() { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1. MySQL: initialize data dir (first run only), start daemon, wait for it.
# ---------------------------------------------------------------------------
if [ ! -d /var/lib/mysql/mysql ]; then
    log "Initializing MySQL data directory..."
    mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql
fi

log "Starting mysqld..."
mysqld_safe --user=mysql --skip-networking=0 --bind-address=127.0.0.1 &

for i in $(seq 1 60); do
    if mysqladmin ping --silent 2>/dev/null; then
        break
    fi
    sleep 1
done
if ! mysqladmin ping --silent 2>/dev/null; then
    log "ERROR: mysqld did not come up in time"
    exit 1
fi
log "MySQL is up."

# ---------------------------------------------------------------------------
# 2. Provision database, app user, and schema (idempotent).
# ---------------------------------------------------------------------------
log "Provisioning database '${DB_NAME}' and user '${DB_USER}'..."
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWD}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

# Schema is tracked in scvis-docker itself (not the cloned repo - see
# mysql-init/schema.sql for why) and was baked into the image at build time.
if [ -f "${SCHEMA_FILE}" ]; then
    log "Applying schema.sql..."
    mysql -u root < "${SCHEMA_FILE}"
else
    log "WARNING: ${SCHEMA_FILE} not found, skipping schema apply"
fi

# ---------------------------------------------------------------------------
# 3. Clone (or refresh) the app source. Never baked into the image - always
#    fetched fresh from git so the container runs exactly what's committed.
#    scvis-go is public, so plain anonymous HTTPS clone works.
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
# 4. scvis-go's main() requires an actual .env file to exist (it does not
#    fall back to reading already-exported process env vars) - write one
#    into the cloned source dir every start. LOCAL_SERVER=true makes it use
#    the repo's own checked-in self-signed dev cert (./tls/localhost.pem).
# ---------------------------------------------------------------------------
log "Writing ${SRC_DIR}/.env..."
cat > "${SRC_DIR}/.env" <<ENV
DB_USER=${DB_USER}
DB_PASSWD=${DB_PASSWD}
DB_NAME=${DB_NAME}
PORT=${CONTAINER_PORT}
LOCAL_SERVER=true
GITHUB_TOKEN=${GITHUB_TOKEN}
GITHUB_OWNER=${GITHUB_OWNER}
GITHUB_REPO=${GITHUB_REPO}
VACCS_HOST=${VACCS_HOST}
VACCS_PORT=${VACCS_PORT}
ENV

# ---------------------------------------------------------------------------
# 5. Seed a default admin user on first run only. scvis-go hashes passwords
#    with bcrypt (cost 12), which bash can't do cleanly - so this runs a
#    small Go program (written here, not part of scvis-go) via `go run`
#    inside the cloned module so it can reuse its bcrypt/mysql dependencies.
# ---------------------------------------------------------------------------
USER_COUNT=$(mysql -u root -N -B -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.users;" 2>/dev/null || echo 0)
if [ "${USER_COUNT}" = "0" ]; then
    log "Seeding default admin user '${SEED_ADMIN_NAME}'..."
    mkdir -p "${SRC_DIR}/cmd/seedadmin"
    cat > "${SRC_DIR}/cmd/seedadmin/main.go" <<'GOEOF'
package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"

	_ "github.com/go-sql-driver/mysql"
	"golang.org/x/crypto/bcrypt"
)

func main() {
	dsn := fmt.Sprintf("%s:%s@/%s?parseTime=true", os.Getenv("DB_USER"), os.Getenv("DB_PASSWD"), os.Getenv("DB_NAME"))
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	hashed, err := bcrypt.GenerateFromPassword([]byte(os.Getenv("SEED_ADMIN_PASSWORD")), 12)
	if err != nil {
		log.Fatal(err)
	}

	_, err = db.Exec(
		"INSERT INTO users (name, email, hashed_password, administrator) VALUES (?, ?, ?, TRUE)",
		os.Getenv("SEED_ADMIN_NAME"), os.Getenv("SEED_ADMIN_EMAIL"), string(hashed),
	)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("admin user seeded")
}
GOEOF
    (cd "${SRC_DIR}" && \
        DB_USER="${DB_USER}" DB_PASSWD="${DB_PASSWD}" DB_NAME="${DB_NAME}" \
        SEED_ADMIN_NAME="${SEED_ADMIN_NAME}" SEED_ADMIN_EMAIL="${SEED_ADMIN_EMAIL}" SEED_ADMIN_PASSWORD="${SEED_ADMIN_PASSWORD}" \
        go run ./cmd/seedadmin)
    log "Default admin login -> name: ${SEED_ADMIN_NAME}  password: ${SEED_ADMIN_PASSWORD}"
fi

# ---------------------------------------------------------------------------
# 6. Compile the app.
# ---------------------------------------------------------------------------
log "Building scvis-web..."
(cd "${SRC_DIR}" && go build -o /opt/scvis-src/scvis-web ./cmd/web)
log "Build complete."

# ---------------------------------------------------------------------------
# 7. Configure networking for the chosen mode, then hand off to the app.
#    scvis-go always serves HTTPS itself (no plain-HTTP mode), so "web" mode
#    uses an nginx TCP passthrough (stream module), not an HTTP reverse
#    proxy - see nginx/scvis.conf.template.
# ---------------------------------------------------------------------------
if [ "${MODE}" = "web" ]; then
    log "Mode=web: nginx will listen on ${CONTAINER_PORT} and pass through to app on 127.0.0.1:${APP_INTERNAL_PORT}"
    sed -i "s/^PORT=.*/PORT=${APP_INTERNAL_PORT}/" "${SRC_DIR}/.env"

    sed -e "s/__LISTEN_PORT__/${CONTAINER_PORT}/g" \
        -e "s/__APP_PORT__/${APP_INTERNAL_PORT}/g" \
        /etc/nginx/stream-templates/scvis.conf.template > /etc/nginx/stream-enabled/scvis.conf

    log "Starting nginx..."
    nginx
else
    log "Mode=local: app will listen directly on 0.0.0.0:${CONTAINER_PORT}"
fi

log "Waiting for vaccs analyzer at ${VACCS_HOST}:${VACCS_PORT}..."
for i in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/${VACCS_HOST}/${VACCS_PORT}") 2>/dev/null; then
        exec 3<&- 3>&-
        break
    fi
    sleep 2
done

log "Starting scvis-web..."
cd "${SRC_DIR}"
exec ./scvis-web
