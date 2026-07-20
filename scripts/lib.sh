#!/bin/bash
# Shared helpers sourced by the other scripts in this directory.

detect_os() {
    case "$(uname -s)" in
        Darwin)            echo "darwin" ;;
        Linux)             echo "linux" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *)                 echo "unknown" ;;
    esac
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# True (0) if something is already listening on 127.0.0.1:$1.
port_in_use() {
    local port="$1"
    if [ "$(detect_os)" = "windows" ]; then
        # Git Bash's bash isn't built with /dev/tcp support, so shell out to
        # the Windows netstat that's already on PATH instead.
        netstat -an 2>/dev/null | grep -qE "127\.0\.0\.1:${port}[[:space:]].*LISTENING"
    else
        (: < "/dev/tcp/127.0.0.1/$port") 2>/dev/null
    fi
}

# Print the first free port at or after $1 (searches at most 50 ports up).
find_free_port() {
    local port="$1"
    local max=$((port + 50))
    while [ "$port" -lt "$max" ]; do
        if ! port_in_use "$port"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    echo "ERROR: no free port found between $1 and $max" >&2
    return 1
}

# Print a host path/socket usable to forward the host's ssh-agent into the
# container, or nothing if no agent with loaded keys is available.
find_ssh_agent_sock() {
    local os
    os="$(detect_os)"
    if [ "$os" = "darwin" ]; then
        # Docker Desktop maps this fixed path to the Mac host's ssh-agent.
        if have_cmd ssh-add && ssh-add -l >/dev/null 2>&1; then
            echo "/run/host-services/ssh-auth.sock"
        fi
    elif [ "$os" = "linux" ]; then
        if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
            echo "${SSH_AUTH_SOCK}"
        fi
    elif [ "$os" = "windows" ]; then
        # Docker Desktop has no fixed forwarding path on Windows; the only
        # case that can work is an SSH_AUTH_SOCK already pointing at a
        # WSL-side agent socket that's mountable into the container.
        if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
            echo "${SSH_AUTH_SOCK}"
        fi
    fi
}

open_browser() {
    local url="$1"
    local os
    os="$(detect_os)"
    if [ "$os" = "darwin" ] && have_cmd open; then
        open "$url"
    elif [ "$os" = "linux" ] && have_cmd xdg-open; then
        xdg-open "$url" >/dev/null 2>&1 &
    elif [ "$os" = "windows" ]; then
        # `start` is a cmd builtin, not a standalone exe; the empty "" is
        # the (required) window title argument, not part of the URL.
        cmd.exe /c start "" "$url" >/dev/null 2>&1
    else
        echo "Open your browser to: $url"
    fi
}

confirm() {
    local prompt="$1"
    local reply
    read -r -p "$prompt [y/N] " reply
    case "$reply" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}
