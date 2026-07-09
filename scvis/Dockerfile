# All-in-one image for running scvis-go locally: MySQL + the compiled Go app,
# optionally fronted by nginx (TCP passthrough - scvis-go always terminates
# its own TLS, see entrypoint.sh/README). Source code is NOT copied in here -
# the entrypoint clones it fresh from git every time the container starts.
FROM golang:1.24-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    default-mysql-server \
    default-mysql-client \
    nginx \
    libnginx-mod-stream \
    git \
    openssh-client \
    tini \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Trust GitHub's host keys up front so `git clone` over SSH doesn't prompt.
RUN mkdir -p /etc/ssh && ssh-keyscan -H github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null

RUN mkdir -p /var/lib/mysql /var/run/mysqld /opt/scvis-src \
    && chown -R mysql:mysql /var/lib/mysql /var/run/mysqld

# nginx's stock config only wires up an `http {}` include directory; "web"
# mode needs a `stream {}` block (raw TCP passthrough, since scvis-go always
# terminates its own TLS - see nginx/scvis.conf.template) so add one here.
RUN mkdir -p /etc/nginx/stream-templates /etc/nginx/stream-enabled \
    && echo 'stream { include /etc/nginx/stream-enabled/*.conf; }' >> /etc/nginx/nginx.conf

# Build context is the repo root (see docker-compose.yml), so paths below
# are relative to it, not to this Dockerfile's directory.
COPY scvis/entrypoint.sh /entrypoint.sh
COPY scvis/nginx/scvis.conf.template /etc/nginx/stream-templates/scvis.conf.template
COPY mysql-init/schema.sql /opt/scvis-docker/schema.sql
RUN chmod +x /entrypoint.sh

# App port (local mode) / nginx port (web mode). Mapped to a host port chosen
# by scripts/run.sh (8080 if free, otherwise the next free port).
EXPOSE 8080

VOLUME ["/var/lib/mysql"]

HEALTHCHECK --interval=5s --timeout=3s --start-period=90s --retries=20 \
    CMD curl -ks "https://127.0.0.1:8080/scvis/" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
