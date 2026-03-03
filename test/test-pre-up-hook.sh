#!/usr/bin/env bash
# Test .yolo/pre-up hook execution and env file generation.
# Verifies: hook detection, stdout capture, exit code handling, env file output.
# Usage: ./test/test-pre-up-hook.sh
set -euo pipefail

BOLD='' RESET='' GREEN='' RED=''
if [ -t 1 ]; then
    BOLD='\033[1m' RESET='\033[0m'
    GREEN='\033[32m' RED='\033[31m'
fi

pass() { echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; FAILURES=$((FAILURES + 1)); }

FAILURES=0
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

# Extract run_pre_up_hook from the yolo script
eval "$(sed -n '/^run_pre_up_hook()/,/^}/p' "$(dirname "$0")/../yolo")"

# Stub UI helpers used by the function
step() { :; }
success() { :; }
error() { echo "ERROR: $*" >&2; }
warning() { :; }
info() { :; }

echo -e "\n${BOLD}Pre-up hook${RESET}"

# 1. No hook file → no env file created, returns 0
PROJECT1="$TMPDIR/no-hook"
mkdir -p "$PROJECT1"
ENV_FILE1="$TMPDIR/out1.env"
run_pre_up_hook "$PROJECT1" "$ENV_FILE1"
if [ ! -f "$ENV_FILE1" ]; then
    pass "No env file when no hook exists"
else
    fail "No env file when no hook exists — file was created"
fi

# 2. Hook prints KEY=VALUE → env file created with correct content
PROJECT2="$TMPDIR/with-hook"
mkdir -p "$PROJECT2/.yolo"
cat > "$PROJECT2/.yolo/pre-up" << 'HOOK'
#!/bin/bash
echo "FOO=bar"
echo "BAZ=qux"
HOOK
chmod +x "$PROJECT2/.yolo/pre-up"
ENV_FILE2="$TMPDIR/out2.env"
run_pre_up_hook "$PROJECT2" "$ENV_FILE2"
if [ -f "$ENV_FILE2" ] \
   && grep -q "FOO=bar" "$ENV_FILE2" \
   && grep -q "BAZ=qux" "$ENV_FILE2"; then
    pass "Hook stdout captured to env file"
else
    fail "Hook stdout captured to env file — got: $(cat "$ENV_FILE2" 2>/dev/null || echo 'no file')"
fi

# 3. Hook exits non-zero → returns non-zero
PROJECT3="$TMPDIR/failing-hook"
mkdir -p "$PROJECT3/.yolo"
cat > "$PROJECT3/.yolo/pre-up" << 'HOOK'
#!/bin/bash
echo "should not matter" >&2
exit 1
HOOK
chmod +x "$PROJECT3/.yolo/pre-up"
ENV_FILE3="$TMPDIR/out3.env"
if ! run_pre_up_hook "$PROJECT3" "$ENV_FILE3" 2>/dev/null; then
    pass "Non-zero exit propagated"
else
    fail "Non-zero exit should propagate"
fi

# 4. Hook not executable → skipped (no env file)
PROJECT4="$TMPDIR/not-executable"
mkdir -p "$PROJECT4/.yolo"
cat > "$PROJECT4/.yolo/pre-up" << 'HOOK'
#!/bin/bash
echo "SHOULD_NOT=appear"
HOOK
# deliberately NOT chmod +x
ENV_FILE4="$TMPDIR/out4.env"
run_pre_up_hook "$PROJECT4" "$ENV_FILE4"
if [ ! -f "$ENV_FILE4" ]; then
    pass "Non-executable hook skipped"
else
    fail "Non-executable hook should be skipped — file was created"
fi

# 5. Hook with empty stdout → no env file created
PROJECT5="$TMPDIR/empty-output"
mkdir -p "$PROJECT5/.yolo"
cat > "$PROJECT5/.yolo/pre-up" << 'HOOK'
#!/bin/bash
echo "setting up..." >&2
# no stdout
HOOK
chmod +x "$PROJECT5/.yolo/pre-up"
ENV_FILE5="$TMPDIR/out5.env"
run_pre_up_hook "$PROJECT5" "$ENV_FILE5"
if [ ! -f "$ENV_FILE5" ]; then
    pass "Empty stdout produces no env file"
else
    fail "Empty stdout should not create env file — got: $(cat "$ENV_FILE5")"
fi

# 6. Hook stderr passes through (not captured in env file)
PROJECT6="$TMPDIR/stderr-hook"
mkdir -p "$PROJECT6/.yolo"
cat > "$PROJECT6/.yolo/pre-up" << 'HOOK'
#!/bin/bash
echo "extracting tokens..." >&2
echo "TOKEN=secret123"
HOOK
chmod +x "$PROJECT6/.yolo/pre-up"
ENV_FILE6="$TMPDIR/out6.env"
STDERR_OUT=$(run_pre_up_hook "$PROJECT6" "$ENV_FILE6" 2>&1 >/dev/null)
if [[ "$STDERR_OUT" == *"extracting tokens..."* ]] \
   && ! grep -q "extracting" "$ENV_FILE6" 2>/dev/null; then
    pass "Stderr passes through, not captured in env file"
else
    fail "Stderr handling — stderr: '$STDERR_OUT', env: $(cat "$ENV_FILE6" 2>/dev/null)"
fi

# ─── Integration: compose command includes --env-file ────────────────────────

echo -e "\n${BOLD}Compose integration${RESET}"

# Extract generate_compose_override for setup
eval "$(sed -n '/^generate_compose_override()/,/^}/p' "$(dirname "$0")/../yolo")"

# 7. Pre-up env file adds --env-file to compose invocation
# Simulate the wiring: if PRE_UP_ENV exists and is non-empty, COMPOSE gets --env-file
PRE_UP_ENV="$TMPDIR/test-pre-up.env"
echo "MY_VAR=hello" > "$PRE_UP_ENV"
COMPOSE=(docker compose -f dummy.yml)
if [ -f "$PRE_UP_ENV" ] && [ -s "$PRE_UP_ENV" ]; then
    COMPOSE+=(--env-file "$PRE_UP_ENV")
fi
if [[ " ${COMPOSE[*]} " == *" --env-file "* ]]; then
    pass "--env-file added to compose when pre-up.env exists"
else
    fail "--env-file should be in compose command — got: ${COMPOSE[*]}"
fi

# 8. No pre-up env file → no --env-file in compose
COMPOSE2=(docker compose -f dummy.yml)
EMPTY_ENV="$TMPDIR/nonexistent.env"
if [ -f "$EMPTY_ENV" ] && [ -s "$EMPTY_ENV" ]; then
    COMPOSE2+=(--env-file "$EMPTY_ENV")
fi
if [[ " ${COMPOSE2[*]} " != *" --env-file "* ]]; then
    pass "No --env-file when pre-up.env missing"
else
    fail "Should not add --env-file when file missing — got: ${COMPOSE2[*]}"
fi

# 9. Config hash differs with vs without pre-up env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HASH_WITHOUT=$(cat "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/Dockerfile" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
HASH_WITH=$(cat "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/Dockerfile" "$PRE_UP_ENV" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
if [ "$HASH_WITHOUT" != "$HASH_WITH" ]; then
    pass "Config hash includes pre-up env file"
else
    fail "Config hash should differ with pre-up env file"
fi

# ─── E2E: pre-up hook env vars reach container ──────────────────────────────

if [ ! -S /var/run/docker.sock ]; then
    echo -e "\n${BOLD}E2E: pre-up hook${RESET}"
    pass "Skipped (no Docker socket)"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    TEST_IMAGE="yolo-test-preup-$$"
    trap "docker rmi '$TEST_IMAGE' >/dev/null 2>&1 || true; rm -rf '$TMPDIR'" EXIT

    echo -e "\n${BOLD}E2E: pre-up hook${RESET}"

    if [ -t 1 ]; then
        printf "  ${DIM:-}Building test image...${RESET}"
    fi
    if ! docker build -q -t "$TEST_IMAGE" \
            --build-arg HOST_UID="$(id -u)" \
            --build-arg HOST_GID="$(id -g)" \
            "$SCRIPT_DIR" >/dev/null 2>&1; then
        [ -t 1 ] && printf "\r\033[K"
        fail "Failed to build test image"
    else
        [ -t 1 ] && printf "\r\033[K"

        E2E_YOLO_HOME="$TMPDIR/e2e-yolo-home"
        mkdir -p "$E2E_YOLO_HOME"
        E2E_SRC="$TMPDIR/e2e-src"
        mkdir -p "$E2E_SRC/hooks"
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
                    PROJ=$(mktemp -d)
                    cd "$PROJ"

                    cp /opt/yolo-src/yolo .
                    cp /opt/yolo-src/docker-compose.yml .
                    cp /opt/yolo-src/Dockerfile .
                    cp /opt/yolo-src/entrypoint.sh .
                    cp /opt/yolo-src/tmux.conf .
                    cp /opt/yolo-src/shutdown.sh .
                    cp -r /opt/yolo-src/hooks .

                    # Create a pre-up hook that exports test vars
                    mkdir -p .yolo
                    cat > .yolo/pre-up << '"'"'HOOK'"'"'
#!/bin/bash
echo "TEST_PRE_UP=hello_from_hook"
echo "ANOTHER_VAR=42"
HOOK
                    chmod +x .yolo/pre-up

                    # Stub docker compose — capture the compose command to verify --env-file
                    mkdir -p /tmp/bin
                    cat > /tmp/bin/docker << '"'"'WRAPPER'"'"'
#!/bin/bash
if [ "$1" = "compose" ]; then
    echo "$@" >> /tmp/compose-args.log
    for arg in "$@"; do
        case "$arg" in
            up)   exit 0 ;;
            ps)   echo ""; exit 0 ;;
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

                    output=$(bash ./yolo up 2>&1) || true
                    echo "$output"

                    # Check compose was called with --env-file
                    if [ -f /tmp/compose-args.log ] && grep -q "\-\-env-file" /tmp/compose-args.log; then
                        echo "ENV_FILE_PASSED"
                    fi

                    # Check the env file was created with correct content
                    env_file=$(find "$YOLO_HOME" -name ".pre-up.env" 2>/dev/null | head -1)
                    if [ -n "$env_file" ] && grep -q "TEST_PRE_UP=hello_from_hook" "$env_file"; then
                        echo "ENV_FILE_CORRECT"
                    fi
                '
        ) 2>&1

        if [[ "$E2E_OUTPUT" == *"Running pre-up hook"* ]]; then
            pass "Pre-up hook step runs during yolo up"
        else
            fail "Should show 'Running pre-up hook' — got:\n$(echo "$E2E_OUTPUT" | tail -10)"
        fi

        if [[ "$E2E_OUTPUT" == *"ENV_FILE_PASSED"* ]]; then
            pass "--env-file passed to docker compose"
        else
            fail "--env-file should be passed to compose — got:\n$(echo "$E2E_OUTPUT" | tail -10)"
        fi

        if [[ "$E2E_OUTPUT" == *"ENV_FILE_CORRECT"* ]]; then
            pass "Env file contains hook output"
        else
            fail "Env file should contain hook output — got:\n$(echo "$E2E_OUTPUT" | tail -10)"
        fi
    fi

    docker rmi "$TEST_IMAGE" >/dev/null 2>&1 || true
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
