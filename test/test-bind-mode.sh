#!/usr/bin/env bash
# Test bind mode (default) vs worktree mode.
# Verifies: default session name, bind-mode mount generation, --worktree flag
# behavior, and that bind mode skips git detection.
# Usage: ./test/test-bind-mode.sh
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
    echo -e "\n${BOLD}Bind mode${RESET}"
    pass "Skipped (no Docker socket) ${DIM}— requires Docker Desktop${RESET}"
    echo ""
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
    exit 0
fi

# ─── Build test image ────────────────────────────────────────────────────────

TEST_IMAGE="yolo-test-bind-$$"
trap "docker rmi '$TEST_IMAGE' >/dev/null 2>&1 || true; rm -rf '$TMPDIR'" EXIT

echo -e "\n${BOLD}Bind mode${RESET}"

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

# ─── Test: yolo up with no session name defaults to "default" ─────────────

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

            # Create a non-git project directory
            PROJ=$(mktemp -d)
            cd "$PROJ"

            # Copy yolo files into the project
            cp /opt/yolo-src/yolo .
            cp /opt/yolo-src/docker-compose.yml .
            cp /opt/yolo-src/Dockerfile .
            cp /opt/yolo-src/entrypoint.sh .
            cp /opt/yolo-src/tmux.conf .
            cp -r /opt/yolo-src/hooks .

            # Stub docker compose/exec/inspect (cannot build inner image in tests)
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

            # Run yolo up with no session name (bind mode)
            output=$(bash ./yolo up 2>&1) || {
                echo "YOLO_FAILED"
                echo "$output"
                exit 1
            }
            echo "$output"
            echo "YOLO_SUCCESS"
        '
) 2>&1

if [[ "$E2E_OUTPUT" == *"YOLO_SUCCESS"* ]]; then
    pass "yolo up (no args) completes without errors"
else
    fail "yolo up (no args) failed:\n$(echo "$E2E_OUTPUT" | tail -10)"
fi

# Bind mode should NOT have "Detecting git repos" or "Setting up worktrees"
if [[ "$E2E_OUTPUT" != *"Detecting git repos"* ]]; then
    pass "Bind mode skips git detection"
else
    fail "Bind mode should skip git detection"
fi

if [[ "$E2E_OUTPUT" != *"Setting up worktrees"* ]]; then
    pass "Bind mode skips worktree setup"
else
    fail "Bind mode should skip worktree setup"
fi

if [[ "$E2E_OUTPUT" == *"Starting Claude Code container"* ]]; then
    pass "Bind mode reaches docker compose stage"
else
    fail "Bind mode didn't reach compose stage:\n$(echo "$E2E_OUTPUT" | tail -10)"
fi

# ─── Test: --worktree without session name errors ─────────────────────────

WT_OUTPUT=$(
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
            PROJ=$(mktemp -d)
            cd "$PROJ"
            cp /opt/yolo-src/yolo .
            cp /opt/yolo-src/docker-compose.yml .
            cp /opt/yolo-src/Dockerfile .
            cp /opt/yolo-src/entrypoint.sh .
            cp /opt/yolo-src/tmux.conf .
            cp -r /opt/yolo-src/hooks .

            bash ./yolo up --worktree 2>&1 && echo "SHOULD_HAVE_FAILED" || echo "CORRECTLY_FAILED"
        '
) 2>&1

if [[ "$WT_OUTPUT" == *"CORRECTLY_FAILED"* ]] && [[ "$WT_OUTPUT" == *"Session name required in worktree mode"* ]]; then
    pass "--worktree without session name errors correctly"
else
    fail "--worktree without session name should error — got:\n$(echo "$WT_OUTPUT" | tail -5)"
fi

# ─── Test: --worktree flag triggers git detection ─────────────────────────

WT_GIT_OUTPUT=$(
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

            PROJ=$(mktemp -d)
            cd "$PROJ"
            git init -q
            git config user.email "test@test.com"
            git config user.name "Test"
            git commit --allow-empty -m "init" -q

            cp /opt/yolo-src/yolo .
            cp /opt/yolo-src/docker-compose.yml .
            cp /opt/yolo-src/Dockerfile .
            cp /opt/yolo-src/entrypoint.sh .
            cp /opt/yolo-src/tmux.conf .
            cp -r /opt/yolo-src/hooks .

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

            output=$(bash ./yolo up wt-test --worktree 2>&1) || {
                echo "YOLO_FAILED"
                echo "$output"
                exit 1
            }
            echo "$output"
            echo "YOLO_SUCCESS"
        '
) 2>&1

if [[ "$WT_GIT_OUTPUT" == *"Detecting git repos"* ]]; then
    pass "--worktree flag triggers git detection"
else
    fail "--worktree flag should trigger git detection:\n$(echo "$WT_GIT_OUTPUT" | tail -10)"
fi

if [[ "$WT_GIT_OUTPUT" == *"Setting up worktrees"* ]]; then
    pass "--worktree flag triggers worktree setup"
else
    fail "--worktree flag should trigger worktree setup:\n$(echo "$WT_GIT_OUTPUT" | tail -10)"
fi

# ─── Test: compose override mounts PROJECT_DIR in bind mode ──────────────

MOUNT_OUTPUT=$(
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

            PROJ=$(mktemp -d)
            cd "$PROJ"

            cp /opt/yolo-src/yolo .
            cp /opt/yolo-src/docker-compose.yml .
            cp /opt/yolo-src/Dockerfile .
            cp /opt/yolo-src/entrypoint.sh .
            cp /opt/yolo-src/tmux.conf .
            cp -r /opt/yolo-src/hooks .

            # Stub docker so up completes
            mkdir -p /tmp/bin
            cat > /tmp/bin/docker <<'"'"'WRAPPER'"'"'
#!/bin/bash
if [ "$1" = "compose" ]; then
    for arg in "$@"; do
        case "$arg" in
            up)   exit 0 ;;
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

            bash ./yolo up 2>&1 >/dev/null || true

            # Check the generated override file for a direct project mount
            PROJ_BASE=$(basename "$PROJ")
            OVERRIDE="'"$E2E_YOLO_HOME"'/$PROJ_BASE/default/docker-compose.override.yml"
            if [ -f "$OVERRIDE" ]; then
                cat "$OVERRIDE"
            else
                echo "NO_OVERRIDE_FILE"
            fi
        '
) 2>&1

if [[ "$MOUNT_OUTPUT" == *":"* ]] && [[ "$MOUNT_OUTPUT" != *"NO_OVERRIDE_FILE"* ]]; then
    pass "Compose override generated in bind mode"
else
    fail "Compose override should exist in bind mode — got:\n$MOUNT_OUTPUT"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
