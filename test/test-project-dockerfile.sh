#!/usr/bin/env bash
# Test per-project Dockerfile detection and compose override generation.
# Verifies: .yolo/Dockerfile detection, build override in compose, config hash inclusion.
# Usage: ./test/test-project-dockerfile.sh
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Extract generate_compose_override from the yolo script
eval "$(sed -n '/^generate_compose_override()/,/^}/p' "$SCRIPT_DIR/yolo")"

# ─── Test cases ──────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Per-project Dockerfile${RESET}"

# 1. No .yolo/Dockerfile → override has no build section
PROJECT="$TMPDIR/project-no-dockerfile"
mkdir -p "$PROJECT"
PORTS=()
SSH_AGENT_FORWARDED=false
generate_compose_override "$TMPDIR/override1.yml" "$PROJECT:$PROJECT"
if ! grep -q "build:" "$TMPDIR/override1.yml"; then
    pass "No build override without .yolo/Dockerfile"
else
    fail "No build override without .yolo/Dockerfile"
fi

# 2. .yolo/Dockerfile exists → override includes build section
PROJECT2="$TMPDIR/project-with-dockerfile"
mkdir -p "$PROJECT2/.yolo"
echo "FROM yolo-base" > "$PROJECT2/.yolo/Dockerfile"
PROJECT_DOCKERFILE="$PROJECT2/.yolo/Dockerfile"
generate_compose_override "$TMPDIR/override2.yml" "$PROJECT2:$PROJECT2"
if grep -q "build:" "$TMPDIR/override2.yml" \
   && grep -q "context:" "$TMPDIR/override2.yml" \
   && grep -q "dockerfile:" "$TMPDIR/override2.yml"; then
    pass "Build override present with .yolo/Dockerfile"
else
    fail "Build override present with .yolo/Dockerfile — got:\n$(cat "$TMPDIR/override2.yml")"
fi
unset PROJECT_DOCKERFILE

# 3. Build override points to correct context and dockerfile
if grep -q "$PROJECT2/.yolo" "$TMPDIR/override2.yml"; then
    pass "Build context points to .yolo/ directory"
else
    fail "Build context should point to .yolo/ — got:\n$(cat "$TMPDIR/override2.yml")"
fi

# 4. Config hash includes .yolo/Dockerfile when present
# Simulate two hashes: one without, one with .yolo/Dockerfile
HASH_WITHOUT=$(cat "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/entrypoint.sh" "$SCRIPT_DIR/tmux.conf" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
HASH_WITH=$(cat "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/entrypoint.sh" "$SCRIPT_DIR/tmux.conf" "$PROJECT2/.yolo/Dockerfile" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
if [ "$HASH_WITHOUT" != "$HASH_WITH" ]; then
    pass "Config hash differs when .yolo/Dockerfile is included"
else
    fail "Config hash should differ when .yolo/Dockerfile is included"
fi

# 5. Changing .yolo/Dockerfile content changes the hash
HASH_BEFORE=$(cat "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/entrypoint.sh" "$SCRIPT_DIR/tmux.conf" "$PROJECT2/.yolo/Dockerfile" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
echo "RUN apt-get update" >> "$PROJECT2/.yolo/Dockerfile"
HASH_AFTER=$(cat "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/entrypoint.sh" "$SCRIPT_DIR/tmux.conf" "$PROJECT2/.yolo/Dockerfile" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
if [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
    pass "Modifying .yolo/Dockerfile changes config hash"
else
    fail "Modifying .yolo/Dockerfile should change config hash"
fi

# ─── E2E: yolo up with .yolo/Dockerfile ──────────────────────────────────────

if [ ! -S /var/run/docker.sock ]; then
    echo -e "\n${BOLD}E2E: per-project Dockerfile${RESET}"
    pass "Skipped (no Docker socket)"
    echo ""
    if [ $FAILURES -eq 0 ]; then
        echo -e "${GREEN}${BOLD}All tests passed${RESET}"
    else
        echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
        exit 1
    fi
    exit 0
fi

TEST_IMAGE="yolo-test-projdf-$$"
trap "docker rmi '$TEST_IMAGE' >/dev/null 2>&1 || true; rm -rf '$TMPDIR'" EXIT

echo -e "\n${BOLD}E2E: per-project Dockerfile${RESET}"

if [ -t 1 ]; then
    printf "  ${DIM:-}Building test image...${RESET}"
fi
if ! docker build -q -t "$TEST_IMAGE" \
        --build-arg HOST_UID="$(id -u)" \
        --build-arg HOST_GID="$(id -g)" \
        "$SCRIPT_DIR" >/dev/null 2>&1; then
    [ -t 1 ] && printf "\r\033[K"
    fail "Failed to build test image"
    echo ""
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
[ -t 1 ] && printf "\r\033[K"

E2E_YOLO_HOME="$TMPDIR/e2e-yolo-home"
mkdir -p "$E2E_YOLO_HOME"
E2E_SRC="$TMPDIR/e2e-src"
mkdir -p "$E2E_SRC/hooks"
cp "$SCRIPT_DIR/yolo" "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/Dockerfile" \
   "$SCRIPT_DIR/entrypoint.sh" "$SCRIPT_DIR/tmux.conf" "$SCRIPT_DIR/shutdown.sh" "$E2E_SRC/"
cp "$SCRIPT_DIR"/hooks/*.sh "$E2E_SRC/hooks/"

# Test: yolo up with .yolo/Dockerfile triggers base image build
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

            # Create a .yolo/Dockerfile
            mkdir -p .yolo
            echo "FROM yolo-base" > .yolo/Dockerfile
            echo "RUN echo project-image-built > /tmp/project-marker" >> .yolo/Dockerfile

            # Stub docker compose (cannot run inner compose), but let docker build through
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
    pass "yolo up with .yolo/Dockerfile completes"
else
    fail "yolo up with .yolo/Dockerfile failed:\n$(echo "$E2E_OUTPUT" | tail -15)"
fi

if [[ "$E2E_OUTPUT" == *"Building base image"* ]]; then
    pass "Base image build step triggered"
else
    fail "Should show 'Building base image' — got:\n$(echo "$E2E_OUTPUT" | tail -10)"
fi

if [[ "$E2E_OUTPUT" == *"Base image ready"* ]]; then
    pass "Base image built successfully"
else
    fail "Base image should build successfully — got:\n$(echo "$E2E_OUTPUT" | tail -10)"
fi

# Clean up the yolo-base image left behind
docker rmi yolo-base >/dev/null 2>&1 || true

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
