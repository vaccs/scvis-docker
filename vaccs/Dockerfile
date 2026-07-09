# Runs the VACCS dynamic-analysis server (vaccs_comm/vc + the Pin-based PAS
# tool) from ../dynamic_analysis. Forced to linux/amd64 (see docker-compose.yml)
# because the vendored Intel Pin binaries under pin/intel64 are x86_64-only -
# on this Apple Silicon host that means Docker Desktop's Rosetta emulation.
# Source is NOT copied in here - entrypoint.sh clones it fresh every start.
FROM ubuntu:noble

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    g++ \
    make \
    curl \
    git \
    openssh-client \
    python3 \
    cmake \
    ninja-build \
    libelf-dev \
    libdwarf-dev \
    libpcre3-dev \
    libxml2-utils \
    libxml2-dev \
    libssl-dev \
    zlib1g-dev \
    tini \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Trust GitHub's host keys up front so `git clone` over SSH doesn't prompt,
# if REPO_URL is ever pointed back at the SSH form (see docker-compose.ssh-agent.yml).
RUN mkdir -p /etc/ssh && ssh-keyscan -H github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null

RUN mkdir -p /opt/vaccs-src

# Build context is the repo root (see docker-compose.yml), so this path is
# relative to it, not to this Dockerfile's directory.
COPY vaccs/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# vaccs_comm/vc's raw TCP protocol port. Never published to the host - only
# reachable from the scvis service over the compose network as vaccs:3580.
EXPOSE 3580

HEALTHCHECK --interval=5s --timeout=3s --start-period=300s --retries=40 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/3580' || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
