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
   "$SCRIPT_DIR/entrypoint.sh" "$SCRIPT_DIR/tmux.conf" "$SCRIPT_DIR/shutdown.sh" "$E2E_SRC/"
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
            cp /opt/yolo-src/shutdown.sh .
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
            cp /opt/yolo-src/shutdown.sh .
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
            cp /opt/yolo-src/shutdown.sh .
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
            cp /opt/yolo-src/shutdown.sh .
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

# ─── Test: mode mismatch detection (worktree → bind) ─────────────────────────

MISMATCH_OUTPUT=$(
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
            cp /opt/yolo-src/shutdown.sh .
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

            # First run: worktree mode — creates .mode file
            output1=$(bash ./yolo up mismatch-test --worktree 2>&1) || true

            # Second run: bind mode (no --worktree), non-interactive
            output2=$(bash ./yolo up mismatch-test 2>&1) || true

            echo "$output2"
            echo "MISMATCH_DONE"
        '
) 2>&1

if [[ "$MISMATCH_OUTPUT" == *"Keeping worktree mode"* ]]; then
    pass "Mode mismatch detected and kept original mode (non-interactive)"
else
    fail "Mode mismatch should auto-keep worktree mode — got:\n$(echo "$MISMATCH_OUTPUT" | tail -15)"
fi

if [[ "$MISMATCH_OUTPUT" == *"Setting up worktrees"* ]]; then
    pass "Mode mismatch: still triggers worktree setup after auto-keep"
else
    fail "Mode mismatch: should trigger worktree setup — got:\n$(echo "$MISMATCH_OUTPUT" | tail -15)"
fi

# ─── Test: conversation data migrated when WORKDIR changes ──────────────────

MIGRATE_OUTPUT=$(
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
            PROJ_BASE=$(basename "$PROJ")

            cp /opt/yolo-src/yolo .
            cp /opt/yolo-src/docker-compose.yml .
            cp /opt/yolo-src/Dockerfile .
            cp /opt/yolo-src/entrypoint.sh .
            cp /opt/yolo-src/tmux.conf .
            cp /opt/yolo-src/shutdown.sh .
            cp -r /opt/yolo-src/hooks .

            # Pre-populate .claude-projects with an old worktree-style key
            OLD_KEY=$(echo "$HOME/.yolo/$PROJ_BASE/migrate-test/$PROJ_BASE" | tr "/." "-")
            NEW_KEY=$(echo "$PROJ" | tr "/." "-")
            PROJECTS_DIR="'"$E2E_YOLO_HOME"'/$PROJ_BASE/migrate-test/.claude-projects"
            mkdir -p "$PROJECTS_DIR/$OLD_KEY"
            echo "conversation-data" > "$PROJECTS_DIR/$OLD_KEY/test-convo.jsonl"

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

            output=$(bash ./yolo up migrate-test 2>&1) || true
            echo "$output"

            # Check: old key should be gone, new key should exist with the data
            if [ -d "$PROJECTS_DIR/$NEW_KEY" ] && [ -f "$PROJECTS_DIR/$NEW_KEY/test-convo.jsonl" ]; then
                echo "MIGRATION_OK"
            else
                echo "MIGRATION_FAILED"
                echo "Expected key: $NEW_KEY"
                ls -la "$PROJECTS_DIR/" 2>&1 || true
            fi
        '
) 2>&1

if [[ "$MIGRATE_OUTPUT" == *"Migrated conversation data"* ]]; then
    pass "Conversation data migration message shown"
else
    fail "Should show migration message — got:\n$(echo "$MIGRATE_OUTPUT" | tail -10)"
fi

if [[ "$MIGRATE_OUTPUT" == *"MIGRATION_OK"* ]]; then
    pass "Conversation data migrated to new project key"
else
    fail "Conversation data should be migrated — got:\n$(echo "$MIGRATE_OUTPUT" | tail -10)"
fi

# ─── Test: conversation data merged when both old and new key dirs exist ──────

MERGE_OUTPUT=$(
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
            PROJ_BASE=$(basename "$PROJ")

            cp /opt/yolo-src/yolo .
            cp /opt/yolo-src/docker-compose.yml .
            cp /opt/yolo-src/Dockerfile .
            cp /opt/yolo-src/entrypoint.sh .
            cp /opt/yolo-src/tmux.conf .
            cp /opt/yolo-src/shutdown.sh .
            cp -r /opt/yolo-src/hooks .

            # Pre-populate BOTH old and new key dirs (simulates the bug scenario)
            OLD_KEY=$(echo "$HOME/.yolo/$PROJ_BASE/merge-test/$PROJ_BASE" | tr "/." "-")
            NEW_KEY=$(echo "$PROJ" | tr "/." "-")
            PROJECTS_DIR="'"$E2E_YOLO_HOME"'/$PROJ_BASE/merge-test/.claude-projects"
            mkdir -p "$PROJECTS_DIR/$OLD_KEY" "$PROJECTS_DIR/$NEW_KEY"

            # Old key has 3 conversations (the real data)
            echo "old-convo-1" > "$PROJECTS_DIR/$OLD_KEY/aaa.jsonl"
            echo "old-convo-2" > "$PROJECTS_DIR/$OLD_KEY/bbb.jsonl"
            echo "old-convo-3" > "$PROJECTS_DIR/$OLD_KEY/ccc.jsonl"
            mkdir -p "$PROJECTS_DIR/$OLD_KEY/memory"
            echo "old-memory" > "$PROJECTS_DIR/$OLD_KEY/memory/MEMORY.md"

            # New key has 1 conversation (created by Claude on brief startup)
            echo "new-convo" > "$PROJECTS_DIR/$NEW_KEY/ddd.jsonl"
            mkdir -p "$PROJECTS_DIR/$NEW_KEY/memory"
            echo "new-memory" > "$PROJECTS_DIR/$NEW_KEY/memory/MEMORY.md"

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

            output=$(bash ./yolo up merge-test 2>&1) || true
            echo "$output"

            # Check: old key should be gone, new key should have all data
            if [ ! -d "$PROJECTS_DIR/$OLD_KEY" ] \
                && [ -f "$PROJECTS_DIR/$NEW_KEY/aaa.jsonl" ] \
                && [ -f "$PROJECTS_DIR/$NEW_KEY/bbb.jsonl" ] \
                && [ -f "$PROJECTS_DIR/$NEW_KEY/ccc.jsonl" ] \
                && [ -f "$PROJECTS_DIR/$NEW_KEY/ddd.jsonl" ]; then
                echo "MERGE_DATA_OK"
            else
                echo "MERGE_DATA_FAILED"
                echo "Old dir exists: $([ -d "$PROJECTS_DIR/$OLD_KEY" ] && echo YES || echo NO)"
                echo "Expected key: $NEW_KEY"
                ls -laR "$PROJECTS_DIR/" 2>&1 || true
            fi

            # New key memory should be preserved (no-clobber)
            if [ -f "$PROJECTS_DIR/$NEW_KEY/memory/MEMORY.md" ] \
                && grep -q "new-memory" "$PROJECTS_DIR/$NEW_KEY/memory/MEMORY.md"; then
                echo "MERGE_NOCLOBBER_OK"
            else
                echo "MERGE_NOCLOBBER_FAILED"
            fi
        '
) 2>&1

if [[ "$MERGE_OUTPUT" == *"MERGE_DATA_OK"* ]]; then
    pass "Both-dirs migration merges old conversations into new key"
else
    fail "Both-dirs migration should merge data — got:\n$(echo "$MERGE_OUTPUT" | tail -15)"
fi

if [[ "$MERGE_OUTPUT" == *"MERGE_NOCLOBBER_OK"* ]]; then
    pass "Both-dirs migration preserves existing data in new key (no-clobber)"
else
    fail "Both-dirs migration should not overwrite new key data — got:\n$(echo "$MERGE_OUTPUT" | tail -10)"
fi

# ─── Test: Shift-Q shutdown triggers container removal and session cleanup ────

SHUTDOWN_OUTPUT=$(
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
            cp /opt/yolo-src/shutdown.sh .
            cp -r /opt/yolo-src/hooks .

            # Stub docker — simulate shutdown scenario:
            # - compose ps returns a container id (already running)
            # - exec with tmux attach exits immediately (simulates detach)
            # - exec with tmux has-session FAILS (session was killed by Shift-Q)
            # - compose down is intercepted and logged
            mkdir -p /tmp/bin
            cat > /tmp/bin/docker <<'"'"'WRAPPER'"'"'
#!/bin/bash
echo "$@" >> /tmp/docker-calls.log
if [ "$1" = "compose" ]; then
    for arg in "$@"; do
        case "$arg" in
            up)   exit 0 ;;
            down) echo "COMPOSE_DOWN_CALLED" >> /tmp/compose-calls.log; exit 0 ;;
            ps)   echo "fake-container-id"; exit 0 ;;
        esac
    done
fi
case "$1" in
    exec)
        # Check if this is a tmux has-session check
        if [[ "$*" == *"tmux has-session"* ]]; then
            exit 1  # Session gone (shutdown)
        fi
        # tmux attach — just exit (simulates detach)
        exit 0
        ;;
    inspect) echo "running"; exit 0 ;;
esac
exec /usr/bin/docker "$@"
WRAPPER
            chmod +x /tmp/bin/docker
            export PATH="/tmp/bin:$PATH"

            # First run: creates session data dir and config hash
            bash ./yolo up shutdown-test 2>&1 >/dev/null || true

            # Second run: fast path (container "already running"), then shutdown
            # Pipe "y" to answer the cleanup prompt
            output=$(echo "y" | bash ./yolo up shutdown-test 2>&1) || true
            echo "$output"

            # Check results
            echo "=== CHECKS ==="
            if grep -q "COMPOSE_DOWN_CALLED" /tmp/compose-calls.log 2>/dev/null; then
                echo "COMPOSE_DOWN_OK"
            else
                echo "COMPOSE_DOWN_MISSING"
            fi

            PROJ_BASE=$(basename "$PROJ")
            SESSION_DIR="'"$E2E_YOLO_HOME"'/$PROJ_BASE/shutdown-test"
            if [ -d "$SESSION_DIR" ]; then
                echo "SESSION_DIR_EXISTS"
            else
                echo "SESSION_DIR_CLEANED"
            fi
        '
) 2>&1

if [[ "$SHUTDOWN_OUTPUT" == *"Removing container"* ]]; then
    pass "Shutdown triggers container removal"
else
    fail "Shutdown should trigger container removal — got:\n$(echo "$SHUTDOWN_OUTPUT" | tail -10)"
fi

if [[ "$SHUTDOWN_OUTPUT" == *"COMPOSE_DOWN_OK"* ]]; then
    pass "docker compose down called on shutdown"
else
    fail "docker compose down should be called — got:\n$(echo "$SHUTDOWN_OUTPUT" | tail -10)"
fi

if [[ "$SHUTDOWN_OUTPUT" == *"Container removed"* ]]; then
    pass "Container removed message shown"
else
    fail "Should show container removed message — got:\n$(echo "$SHUTDOWN_OUTPUT" | tail -10)"
fi

if [[ "$SHUTDOWN_OUTPUT" == *"SESSION_DIR_CLEANED"* ]]; then
    pass "Session data cleaned up after user confirms"
else
    fail "Session data should be cleaned up — got:\n$(echo "$SHUTDOWN_OUTPUT" | tail -10)"
fi

if [[ "$SHUTDOWN_OUTPUT" == *"Session cleaned up"* ]]; then
    pass "Session cleanup confirmation shown"
else
    fail "Should show cleanup confirmation — got:\n$(echo "$SHUTDOWN_OUTPUT" | tail -10)"
fi

# ─── Test: unknown flags are rejected ─────────────────────────────────────

UNKNOWN_FLAG_OUTPUT=$(
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
            cp /opt/yolo-src/shutdown.sh .
            cp -r /opt/yolo-src/hooks .

            bash ./yolo up test --workstree 2>&1 && echo "SHOULD_HAVE_FAILED" || echo "CORRECTLY_FAILED"
        '
) 2>&1

if [[ "$UNKNOWN_FLAG_OUTPUT" == *"CORRECTLY_FAILED"* ]] && [[ "${UNKNOWN_FLAG_OUTPUT,,}" == *"unknown flag"* ]]; then
    pass "Unknown flag --workstree is rejected"
else
    fail "Unknown flags should be rejected — got:\n$(echo "$UNKNOWN_FLAG_OUTPUT" | tail -5)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
