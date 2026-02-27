#!/usr/bin/env bash
# Test nested yolo (Docker outside of Docker) support.
# Builds the real yolo image, runs ./yolo up inside a container with the Docker
# socket mounted, and verifies it completes without errors. This catches runtime
# bugs (like `local` outside a function) that unit tests miss.
# Usage: ./test/test-nested.sh
set -euo pipefail

BOLD='' RESET='' GREEN='' RED='' DIM=''
if [ -t 1 ]; then
    BOLD='\033[1m' RESET='\033[0m'
    GREEN='\033[32m' RED='\033[31m' DIM='\033[2m'
fi

pass() { echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; FAILURES=$((FAILURES + 1)); }

FAILURES=0
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -S /var/run/docker.sock ]; then
    echo -e "\n${BOLD}Nested yolo${RESET}"
    pass "Skipped (no Docker socket) ${DIM}— requires Docker Desktop${RESET}"
    echo ""
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
    exit 0
fi

# ─── Build test image ────────────────────────────────────────────────────────

TEST_IMAGE="yolo-test-nested-$$"
trap "docker rmi '$TEST_IMAGE' >/dev/null 2>&1 || true; rm -rf '$TMPDIR'" EXIT

echo -e "\n${BOLD}Nested yolo${RESET}"

if [ -t 1 ]; then
    printf "  ${DIM}Building test image...${RESET}"
fi
if ! docker build -q -t "$TEST_IMAGE" \
        --build-arg HOST_UID="$(id -u)" \
        --build-arg HOST_GID="$(id -g)" \
        "$SCRIPT_DIR" >/dev/null 2>&1; then
    [ -t 1 ] && printf "\r\033[K"
    fail "Failed to build test image"
    echo ""
    echo -e "${RED}${BOLD}1 test(s) failed${RESET}"
    exit 1
fi
[ -t 1 ] && printf "\r\033[K"

# ─── Docker socket access ────────────────────────────────────────────────────
# Verify the claude user can talk to the Docker daemon via the mounted socket.

DOCKER_OUTPUT=$(
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --entrypoint /bin/bash \
        "$TEST_IMAGE" \
        -c '
            # Reproduce the entrypoint socket fix
            if [ -S /var/run/docker.sock ] && ! docker info >/dev/null 2>&1; then
                DOCKER_SOCK_GID=$(stat -c "%g" /var/run/docker.sock)
                if [ "$DOCKER_SOCK_GID" -eq 0 ]; then
                    sudo chmod 666 /var/run/docker.sock
                else
                    DOCKER_GROUP=$(getent group "$DOCKER_SOCK_GID" 2>/dev/null | cut -d: -f1) || true
                    if [ -z "$DOCKER_GROUP" ]; then
                        DOCKER_GROUP="docker-host"
                        sudo groupadd -g "$DOCKER_SOCK_GID" "$DOCKER_GROUP"
                    fi
                    sudo usermod -aG "$DOCKER_GROUP" claude
                    exec sg "$DOCKER_GROUP" -c "docker info --format={{.ServerVersion}} 2>&1"
                fi
            fi
            docker info --format="{{.ServerVersion}}" 2>&1
        '
) 2>&1

if [ $? -eq 0 ] && [[ "$DOCKER_OUTPUT" =~ [0-9]+\.[0-9]+ ]]; then
    pass "claude user can run docker info inside container"
else
    fail "docker info failed inside container — got: $DOCKER_OUTPUT"
fi

# ─── End-to-end: ./yolo up inside container ───────────────────────────────────
# Run the actual yolo script inside a container with the Docker socket mounted.
# Docker compose up/ps/exec are stubbed (we can't build a real inner image in a
# test), but all bash logic in yolo runs for real.

E2E_SRC="$TMPDIR/e2e-src"
E2E_YOLO_HOME="$TMPDIR/e2e-yolo-home"
mkdir -p "$E2E_SRC/hooks" "$E2E_YOLO_HOME"
cp "$SCRIPT_DIR/yolo" "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/Dockerfile" \
   "$SCRIPT_DIR/entrypoint.sh" "$SCRIPT_DIR/tmux.conf" "$E2E_SRC/"
cp "$SCRIPT_DIR"/hooks/*.sh "$E2E_SRC/hooks/"

E2E_OUTPUT=$(
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$E2E_SRC:/opt/yolo-src:ro" \
        -v "$E2E_YOLO_HOME:$E2E_YOLO_HOME" \
        -e YOLO_HOST_HOME="$HOME" \
        -e YOLO_HOME="$E2E_YOLO_HOME" \
        -e ANTHROPIC_API_KEY="sk-test-fake" \
        --entrypoint /bin/bash \
        "$TEST_IMAGE" \
        -c '
            set -e

            # Create a fake project with a git repo
            PROJ=$(mktemp -d)
            cd "$PROJ"
            git init -q
            git config user.email "test@test.com"
            git config user.name "Test"
            git commit --allow-empty -m "init" -q

            # Copy yolo files into the project
            cp /opt/yolo-src/yolo .
            cp /opt/yolo-src/docker-compose.yml .
            cp /opt/yolo-src/Dockerfile .
            cp /opt/yolo-src/entrypoint.sh .
            cp /opt/yolo-src/tmux.conf .
            cp -r /opt/yolo-src/hooks .

            # Stub docker: let real docker handle "info" (yolo checks daemon is
            # running), but intercept compose up/ps/exec since we cannot build
            # an inner image in a test.
            mkdir -p /tmp/bin
            cat > /tmp/bin/docker <<'"'"'WRAPPER'"'"'
#!/bin/bash
if [ "$1" = "compose" ]; then
    for arg in "$@"; do
        case "$arg" in
            up)   echo "COMPOSE_UP_INTERCEPTED" >> /tmp/compose-calls.log; exit 0 ;;
            ps)   echo "fake-container-id"; exit 0 ;;
        esac
    done
fi
case "$1" in
    exec)    exit 0 ;;
    inspect) echo "running"; exit 0 ;;
esac
exec /usr/bin/docker "$@"
WRAPPER
            chmod +x /tmp/bin/docker
            export PATH="/tmp/bin:$PATH"

            # Run yolo up (non-interactive, non-TTY)
            output=$(bash ./yolo up e2e-test 2>&1) || {
                echo "YOLO_FAILED"
                echo "$output"
                exit 1
            }
            echo "$output"
            echo "YOLO_SUCCESS"
        '
) 2>&1

if [[ "$E2E_OUTPUT" == *"YOLO_SUCCESS"* ]]; then
    pass "yolo up completes without errors inside container"
else
    fail "yolo up failed inside container:\n$(echo "$E2E_OUTPUT" | tail -10)"
fi

if [[ "$E2E_OUTPUT" == *"Starting Claude Code container"* ]]; then
    pass "yolo up reached docker compose stage"
else
    fail "yolo up didn't reach compose stage:\n$(echo "$E2E_OUTPUT" | tail -10)"
fi

if [[ "$E2E_OUTPUT" == *"Attaching to tmux session"* ]]; then
    pass "yolo up completed full lifecycle"
else
    fail "yolo up didn't complete lifecycle:\n$(echo "$E2E_OUTPUT" | tail -10)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
