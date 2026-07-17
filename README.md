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

## Apple Silicon: Pin doesn't run under Rosetta emulation

**This section only applies when your host isn't already x86_64** (e.g. an
Apple Silicon Mac, or an ARM Linux box). On a native x86_64 Linux machine,
`vaccs`'s `platform: linux/amd64` is a no-op - there's no translation layer
in the way, Pin's ptrace-based instrumentation works exactly as it would
outside Docker, and nothing in this section applies to you.

On Apple Silicon, Pin does its own low-level binary instrumentation
(ptrace-based process injection), and that doesn't survive being run on top
of Rosetta 2's own amd64->arm64 translation - even with every Docker
restriction relaxed (`--cap-add=SYS_PTRACE --security-opt seccomp=unconfined
--security-opt apparmor=unconfined`), Pin's injector fails with
`Attach to pid N failed: Function not implemented`, and the target process
gets killed. This is a platform limitation, not a scvis-docker bug - the
`vaccs` container builds and starts fine on Apple Silicon, and the network
handshake with `scvis` completes, but real analysis runs can't complete on
this host.

The fix is to run on genuine x86_64 hardware instead of translated amd64.
This repo includes a `.devcontainer/devcontainer.json` for that: open it in
a [GitHub Codespace](https://github.com/features/codespaces) (real x86_64
Azure VMs, no emulation layer at all) and run `scripts/run.sh` there exactly
as you would locally. Notes:

- Uses the `docker-in-docker` devcontainer feature, since the Codespace
  itself is a container.
- Requests a 4-core/8GB machine - building Pin/cppcheck/scvis-go/MySQL
  together is heavy; the Codespaces default (2-core) will be slow.
- Codespaces' port-forwarding proxy sits in front of the forwarded port with
  its own auth/HTTPS, separate from the plain-HTTP `local` mode described
  below - so scvis is reached through GitHub's forwarding UI, not a bare
  `http://localhost:8080`.

### Why both services run together in the Codespace

An earlier version of this setup tried to run `vaccs` in a Codespace while
keeping `scvis` local, tunneling `vaccs`'s port back over `gh codespace
ports forward` (or raw `ssh -L`, which turned out to share the same
underlying transport - both go through `gh cs ssh --stdio`). That doesn't
work: `vaccs_comm`'s protocol is a series of small, low-latency binary
messages, and bytes reliably went missing somewhere in GitHub's Codespaces
port-forwarding path - every single test connection failed at the very
first message, with the client seeing a clean write locally but `vaccs`
never receiving the bytes at all. This isn't a scvis-docker bug - it's a
limitation of that transport for this kind of raw, low-latency protocol -
so there's no tunnel-based split here. Run both services in the Codespace
(`scripts/run.sh`, same as locally); `vaccs_comm` traffic then stays on the
Codespace's own Docker network the whole time, exactly as it would on real
x86_64 hardware, and only ordinary HTTP (browser to `scvis`) goes through
Codespaces' (well-tested) port forwarding.

## Prerequisites

Just Docker + Compose v2. `run.sh` checks for these and, if missing, offers
to install/start them for you (`scripts/install-prereqs.sh`) - but that
auto-install path needs permissions you may not have:

- **Linux**: `sudo`, to run `get.docker.com`, enable the `docker` systemd
  service, install `docker-compose-plugin`, and add you to the `docker`
  group. If you were just added to that group, log out and back in (or run
  `newgrp docker`) before re-running - group membership doesn't take effect
  in the shell you're already in, so the very next command can still fail
  even though the install "succeeded".
- **macOS**: Homebrew + admin rights, to install Docker Desktop via
  `brew install --cask docker`.

If you don't have those permissions and Docker isn't already installed and
running, `install-prereqs.sh` will simply fail (either the `confirm` prompt
has nothing useful to say yes to, or the `sudo`/Homebrew call itself fails).
Either get Docker installed some other way (ask whoever administers the
machine), or use the GitHub Codespace described below - it provisions
Docker inside the Codespace VM itself, so it works with no local install
permissions at all, not just as an Apple Silicon workaround.

`curl` is also assumed to be on the host (used by both the install check
and `run.sh`'s health-check loop) - present by default on virtually every
dev machine and in the devcontainer.

## Quick start

```bash
git clone https://github.com/vaccs/scvis-docker.git
cd scvis-docker
scripts/run.sh          # "local" mode: nginx terminates TLS, served over plain HTTP
scripts/run.sh web      # "web" mode: nginx passes the app's HTTPS through unchanged
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
scripts/stop.sh --debug      # also save vaccs's error log to ./vaccs_error.log first
```

## The two modes

In both modes the compiled app binds `8081` (not published) inside the
`scvis` container, and nginx listens on the published `0.0.0.0:8080`.
scvis-go's `cmd/web/main.go` always calls `ListenAndServeTLS` with its own
checked-in self-signed dev certificate (`tls/localhost.pem`) - there's no
plain-HTTP mode built into the app - so the two modes differ in what nginx
does with that TLS connection:

- **local** (default) - nginx **terminates** the app's TLS itself and
  re-serves plain HTTP to the host, so you get `http://127.0.0.1:8080/scvis/`
  with no browser certificate warning. It also strips the `Secure` flag off
  the app's session cookie (which scvis-go always sets, regardless of
  scheme) so logging in still works over plain HTTP. See
  `scvis/nginx/scvis-local.conf.template`.
- **web** - nginx does a raw **TCP passthrough** (the `stream` module)
  instead, forwarding encrypted bytes without ever decrypting them, so the
  self-signed cert reaches the browser as-is - exactly as it would running
  scvis-go natively. Unlike eevis-docker/irvis-docker this is not an HTTP
  reverse proxy, since there's no plain-HTTP backend to proxy to. See
  `scvis/nginx/scvis.conf.template`.

In both modes the container's internal (published) port is always 8080; only
the *host* port that maps to it changes if 8080 is busy.

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

Upstream `scvis-go`'s `internal/vaccs/vaccs_comm.go` hardcodes
`net.DialTimeout("tcp", "localhost:3580", ...)`. Since `vaccs` runs in its
own container here (needed for the amd64/Pin requirement), that address is
unreachable - it's only reachable as `vaccs:3580` over the compose network -
so `scvis/entrypoint.sh` patches the freshly-cloned source on every start
(`sed`, right after the clone/fetch step, before compiling) to read the
host/port from `VACCS_HOST`/`VACCS_PORT` env vars instead, falling back to
`localhost:3580` unchanged when they're unset so native/non-Docker use is
unaffected. `docker-compose.yml` sets `VACCS_HOST=vaccs` for the `scvis`
service so it reaches the analyzer over the compose network. Nothing needs
to be forked or patched upstream for this to work.

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
| `scvis/nginx/scvis-local.conf.template` | TLS-terminating HTTP reverse proxy config used in `local` mode |
| `vaccs/Dockerfile`, `vaccs/entrypoint.sh` | dynamic_analysis (VACCS/Pin) container, amd64 |
| `mysql-init/schema.sql` | Authoritative DB schema, applied on every start |
| `docker-compose.yml` | Both services |
| `docker-compose.ssh-agent.yml` | Overlay adding ssh-agent forwarding to both |
| `scripts/install-prereqs.sh` | Installs/starts Docker if missing |
| `scripts/run.sh` | Main entry point (see Quick start) - also what to run inside a Codespace |
| `scripts/stop.sh` | Tears the containers down |
| `scripts/lib.sh` | Shared shell helpers |
| `.devcontainer/devcontainer.json` | GitHub Codespaces config (native x86_64, see Apple Silicon note above) |
