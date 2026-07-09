#!/bin/bash
# Makes sure Docker (+ Compose v2) is installed and the daemon is running.
# Asks before making any system-wide change (installing Homebrew/Docker
# Desktop, running get.docker.com, adding you to the docker group, etc).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./lib.sh
source ./lib.sh

OS="$(detect_os)"

install_docker_darwin() {
    if ! have_cmd brew; then
        echo "Homebrew is required to install Docker Desktop automatically."
        if confirm "Install Homebrew now?"; then
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        else
            echo "Please install Docker Desktop manually: https://www.docker.com/products/docker-desktop/"
            exit 1
        fi
    fi

    if ! have_cmd docker; then
        if confirm "Docker is not installed. Install Docker Desktop via Homebrew now?"; then
            brew install --cask docker
        else
            echo "Please install Docker Desktop manually: https://www.docker.com/products/docker-desktop/"
            exit 1
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        echo "Starting Docker Desktop..."
        open -a Docker
        echo -n "Waiting for the Docker daemon to come up"
        for _ in $(seq 1 60); do
            docker info >/dev/null 2>&1 && { echo; return 0; }
            echo -n "."
            sleep 2
        done
        echo
        echo "Docker Desktop hasn't finished starting yet."
        echo "It may need one-time manual setup (privileged helper install / license)."
        echo "Open the Docker Desktop app, complete any prompts, then re-run this script."
        exit 1
    fi
}

install_docker_linux() {
    if ! have_cmd docker; then
        if confirm "Docker is not installed. Install it now via get.docker.com (requires sudo)?"; then
            curl -fsSL https://get.docker.com | sudo sh
        else
            echo "Please install Docker manually: https://docs.docker.com/engine/install/"
            exit 1
        fi
    fi

    if have_cmd systemctl; then
        sudo systemctl enable --now docker || true
    fi

    if ! docker compose version >/dev/null 2>&1 && ! have_cmd docker-compose; then
        if confirm "Docker Compose plugin not found. Install docker-compose-plugin now?"; then
            if have_cmd apt-get; then
                sudo apt-get update && sudo apt-get install -y docker-compose-plugin
            elif have_cmd dnf; then
                sudo dnf install -y docker-compose-plugin
            else
                echo "Please install the Docker Compose plugin manually for your distro."
                exit 1
            fi
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        if groups "$USER" | grep -qw docker; then
            echo "The docker daemon isn't reachable yet. Try again in a new shell (group membership needs a re-login)."
        else
            if confirm "Add $USER to the docker group so you don't need sudo for docker commands?"; then
                sudo usermod -aG docker "$USER"
                echo "Added. Log out and back in (or run 'newgrp docker'), then re-run this script."
            fi
        fi
        exit 1
    fi
}

case "$OS" in
    darwin) install_docker_darwin ;;
    linux)  install_docker_linux ;;
    *)
        echo "Unsupported OS for auto-install: $(uname -s)"
        echo "Please install Docker + Compose v2 manually: https://docs.docker.com/get-docker/"
        exit 1
        ;;
esac

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: 'docker compose' (v2) is required but not available." >&2
    exit 1
fi

echo "Docker is installed and running."
