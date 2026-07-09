# scvis-docker

Run [scvis-go](https://github.com/vaccs/scvis-go) and its
[dynamic_analysis](https://github.com/vaccs/dynamic_analysis) VACCS/Pin
analyzer locally in Docker. Source code is never copied from your local
checkout - each container start does a fresh `git clone`/`git fetch` of the
real repos, then compiles them, so you're always running exactly what's
committed.

Unlike eevis-docker/irvis-docker, this is **two containers**, not one:

- **`scvis`** - MySQL + the compiled scvis-go web app (+ nginx in `web`
  mode). Runs on this host's native architecture.
- **`vaccs`** - the VACCS dynamic-analysis server
  (`dynamic_analysis/vaccs_comm/vc`, built on a vendored Intel Pin). Forced
  to **`linux/amd64`**, because Pin's binaries (`pin/intel64`) are x86_64-only.
  On Apple Silicon this runs via Docker Desktop's Rosetta-based amd64
  emulation - enable "Use Rosetta for x86_64/amd64 emulation" in Docker
  Desktop's settings if you haven't already.

`scvis` talks to `vaccs` over the compose network (`vaccs:3580`) - see
"scvis-go patch" below.

## Quick start

```bash
cd scvis-docker
scripts/run.sh          # "local" mode: app served directly
scripts/run.sh web      # "web" mode: nginx passes through to the app
```

`run.sh`:
1. Checks that Docker + Compose v2 are installed and the daemon is running -
   installs/starts them if not (asks before making any system change).
2. Forwards your ssh-agent into both containers if one is available (not
   required - both upstream repos are public, see below).
3. Picks a host port, starting at 8080 and moving up if it's already taken.
4. Runs `docker compose up --build` (the first run is slow - it compiles
   dynamic_analysis + cppcheck from source under amd64 emulation, plus
   scvis-go and MySQL).
5. Waits for the app to respond.
6. Opens your default browser to it.

Stop it with:

```bash
scripts/stop.sh              # stop, keep the database
scripts/stop.sh --wipe-db    # stop and delete the MySQL volume
```

## The two modes

- **local** - the compiled app binds `0.0.0.0:8080` inside the `scvis`
  container and is exposed directly to the host.
- **web** - the app binds `8081` (not published) and nginx listens on
  `0.0.0.0:8080`. Unlike eevis-docker/irvis-docker, this is a raw **TCP
  passthrough** (nginx's `stream` module), not an HTTP reverse proxy:
  scvis-go's `cmd/web/main.go` always calls `ListenAndServeTLS` - there's no
  plain-HTTP mode to proxy to - so nginx just forwards encrypted bytes
  without ever terminating TLS itself.

In both modes the container's internal port is always 8080; only the *host*
port that maps to it changes if 8080 is busy.

The app always serves HTTPS with scvis-go's own checked-in self-signed dev
certificate (`tls/localhost.pem`) - your browser will warn about it, exactly
as it would running scvis-go natively.

## Configuration

Copy `.env.example` to `.env` to override defaults (DB credentials, GitHub
integration, seeded admin account, which refs to clone). `run.sh` creates
`.env` for you on first run if it doesn't exist.

A default admin user (`admin` / `admin1234` unless overridden in `.env`) is
seeded the first time the `users` table is empty.

## Cloning the repos

Both `scvis-go` and `dynamic_analysis` are public, so the default HTTPS URLs
clone with no authentication at all - nothing is copied into the images, the
containers just do a normal anonymous `git clone`/`git fetch`.

If either ever goes private, `run.sh` also detects a running host ssh-agent
with loaded keys (`ssh-add -l`) and forwards it into both containers (via
Docker Desktop's `/run/host-services/ssh-auth.sock` on macOS, or your real
`$SSH_AUTH_SOCK` on Linux) so `git clone`/`git fetch` can authenticate with
your existing keys - just set that repo's `REPO_URL` in `.env` back to the
SSH form (e.g. `git@github.com:vaccs/scvis-go.git`).

`dynamic_analysis`'s `.gitmodules` still lists a `libelfincpp98` submodule,
but that's unused now (Pin's own libdwarf covers what it used to provide),
so `vaccs/entrypoint.sh` does a plain clone that doesn't fetch it.

## scvis-go patch: configurable VACCS host

`scvis-go`'s `internal/vaccs/vaccs_comm.go` originally hardcoded
`net.DialTimeout("tcp", "localhost:3580", ...)`. Since `vaccs` now runs in
its own container (needed for the amd64/Pin requirement), this repo depends
on a small patch to `scvis-go` (applied to your local `scvis-go` checkout,
not shipped from here) that reads the host/port from `VACCS_HOST`/
`VACCS_PORT` env vars, defaulting to `localhost:3580` so non-Docker/native
behavior is unchanged. `docker-compose.yml` sets `VACCS_HOST=vaccs` for the
`scvis` service so it reaches the analyzer over the compose network.

## Database schema

The schema applied on every start comes from `mysql-init/schema.sql` in this
repo, not from the cloned scvis-go source: scvis-go's own
`scripts/scvis_backup.sql` is a data dump of a stale schema (missing the
`administrator` column that `internal/models/users.go` actually uses), so
the up-to-date schema (6 tables, including the `sessions` table required by
`alexedwards/scs/mysqlstore`) is tracked here instead.

## What's in each container

**scvis**: MySQL server (data persisted in the `mysql-data` volume), Go
toolchain (rebuilds scvis-go every start), nginx (`web` mode only), git +
openssh-client.

**vaccs**: build toolchain for `dynamic_analysis` (gcc/g++/make/cmake/ninja
+ the analysis-specific libs its Dockerfile lists), git + openssh-client.
Rebuilt from source every start - nothing is baked in except system
packages.

See `scvis/Dockerfile`+`scvis/entrypoint.sh` and
`vaccs/Dockerfile`+`vaccs/entrypoint.sh` for the exact startup sequence of
each.

## Files

| File | Purpose |
|---|---|
| `scvis/Dockerfile`, `scvis/entrypoint.sh` | scvis-go + MySQL container |
| `scvis/nginx/scvis.conf.template` | TCP-passthrough config used in `web` mode |
| `vaccs/Dockerfile`, `vaccs/entrypoint.sh` | dynamic_analysis (VACCS/Pin) container, amd64 |
| `mysql-init/schema.sql` | Authoritative DB schema, applied on every start |
| `docker-compose.yml` | Both services |
| `docker-compose.ssh-agent.yml` | Overlay adding ssh-agent forwarding to both |
| `scripts/install-prereqs.sh` | Installs/starts Docker if missing |
| `scripts/run.sh` | Main entry point (see Quick start) |
| `scripts/stop.sh` | Tears the containers down |
| `scripts/lib.sh` | Shared shell helpers |
