# Per-Project Dockerfile Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow projects to extend the base yolo Docker image with a `.yolo/Dockerfile` that layers project-specific tooling on top.

**Architecture:** Two-stage build — `yolo up` first builds the base image as `yolo-base`, then (if `.yolo/Dockerfile` exists) builds the project image FROM it. The compose override is extended to point at the project Dockerfile when present.

**Tech Stack:** Bash, Docker, Docker Compose

---

### Task 1: Write the test file

**Files:**
- Create: `test/test-project-dockerfile.sh`

**Step 1: Write the test**

Create `test/test-project-dockerfile.sh` following the pattern from `test/test-compose-override.sh` (extract functions from `yolo`, test in isolation):

```bash
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

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
```

**Step 2: Run the test to verify it fails**

Run: `bash test/test-project-dockerfile.sh`
Expected: FAIL — `generate_compose_override` doesn't know about `PROJECT_DOCKERFILE` yet, so test 2 fails.

**Step 3: Commit**

```bash
git add test/test-project-dockerfile.sh
git commit -m "test: add per-project Dockerfile tests (red)"
```

---

### Task 2: Modify `generate_compose_override` to emit build section

**Files:**
- Modify: `yolo:698-723` (`generate_compose_override` function)

**Step 1: Add build override logic**

Add a build section to the generated compose override when the global `PROJECT_DOCKERFILE` is set. Insert after the environment block (line 721), before the closing redirect:

```bash
generate_compose_override() {
    local override_file="$1"
    shift
    local mounts=("$@")

    mkdir -p "$(dirname "$override_file")"

    {
        echo "services:"
        echo "  claude:"
        if [ -n "${PROJECT_DOCKERFILE:-}" ]; then
            echo "    build:"
            echo "      context: $(dirname "$PROJECT_DOCKERFILE")"
            echo "      dockerfile: Dockerfile"
        fi
        echo "    volumes:"
        for mount in "${mounts[@]}"; do
            echo "      - ${mount}"
        done
        if [ ${#PORTS[@]} -gt 0 ]; then
            echo "    ports:"
            for port in "${PORTS[@]}"; do
                echo "      - \"${port}:${port}\""
            done
        fi
        if [ "${SSH_AGENT_FORWARDED:-false}" = "true" ]; then
            echo "    environment:"
            echo "      SSH_AUTH_SOCK: /run/host-services/ssh-auth.sock"
        fi
    } > "$override_file"
}
```

**Step 2: Run test to verify tests 1-3 pass**

Run: `bash test/test-project-dockerfile.sh`
Expected: Tests 1-3 pass (build override present/absent, correct context path). Tests 4-5 pass trivially (they test hashing logic independent of the function).

**Step 3: Run all existing tests to verify no regressions**

Run: `make test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add yolo
git commit -m "feat: generate build override for per-project Dockerfile"
```

---

### Task 3: Build base image and wire up detection in `cmd_up`

**Files:**
- Modify: `yolo:1573-1594` (compose setup and config hash in `cmd_up`)

**Step 1: Add base image build and project Dockerfile detection**

After the compose override is generated (line 1574) and before the compose command is assembled (line 1576), add detection and base image build logic. Also update the config hash (line 1594) to include `.yolo/Dockerfile`.

Find this block (around line 1573):
```bash
    # Generate compose override
    generate_compose_override "$OVERRIDE_FILE" "${MOUNTS[@]}"

    COMPOSE=(docker compose -p "$CONTAINER_PREFIX" -f "$YOLO_LIB/docker-compose.yml" -f "$OVERRIDE_FILE")
```

Replace with:
```bash
    # Detect per-project Dockerfile
    if [ -f "$PROJECT_DIR/.yolo/Dockerfile" ]; then
        export PROJECT_DOCKERFILE="$PROJECT_DIR/.yolo/Dockerfile"
    fi

    # Generate compose override
    generate_compose_override "$OVERRIDE_FILE" "${MOUNTS[@]}"

    # Build base image when project Dockerfile needs it
    if [ -n "${PROJECT_DOCKERFILE:-}" ]; then
        step "Building base image"
        BASE_BUILD_ARGS=(
            --build-arg "HOST_UID=$HOST_UID"
            --build-arg "HOST_GID=$HOST_GID"
        )
        [ -n "${CLAUDE_VERSION:-}" ] && BASE_BUILD_ARGS+=(--build-arg "CLAUDE_VERSION=$CLAUDE_VERSION")
        if [ "$VERBOSE" = "true" ]; then
            docker build -t yolo-base "${BASE_BUILD_ARGS[@]}" -f "$YOLO_LIB/Dockerfile" "$YOLO_LIB"
        else
            BASE_BUILD_LOG="$YOLO_TMPDIR/base-build-log"
            if ! docker build -t yolo-base "${BASE_BUILD_ARGS[@]}" -f "$YOLO_LIB/Dockerfile" "$YOLO_LIB" >"$BASE_BUILD_LOG" 2>&1; then
                error "Base image build failed:"
                tail -20 "$BASE_BUILD_LOG" | sed 's/^/  /'
                exit 1
            fi
        fi
        success "Base image ready"
    fi

    COMPOSE=(docker compose -p "$CONTAINER_PREFIX" -f "$YOLO_LIB/docker-compose.yml" -f "$OVERRIDE_FILE")
```

**Step 2: Update config hash to include `.yolo/Dockerfile`**

Find (line 1594):
```bash
    CONFIG_HASH=$(cat "$YOLO_LIB/docker-compose.yml" "$OVERRIDE_FILE" "$YOLO_LIB/Dockerfile" "$YOLO_LIB/entrypoint.sh" "$YOLO_LIB/tmux.conf" "${USER_OVERRIDES[@]}" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
```

Replace with:
```bash
    HASH_FILES=("$YOLO_LIB/docker-compose.yml" "$OVERRIDE_FILE" "$YOLO_LIB/Dockerfile" "$YOLO_LIB/entrypoint.sh" "$YOLO_LIB/tmux.conf" "${USER_OVERRIDES[@]}")
    [ -n "${PROJECT_DOCKERFILE:-}" ] && HASH_FILES+=("$PROJECT_DOCKERFILE")
    CONFIG_HASH=$(cat "${HASH_FILES[@]}" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
```

**Step 3: Run all tests**

Run: `make test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add yolo
git commit -m "feat: build base image and detect .yolo/Dockerfile in up"
```

---

### Task 4: Add E2E test with real Docker build

**Files:**
- Modify: `test/test-project-dockerfile.sh`

**Step 1: Add an E2E test**

Append an E2E test section to `test/test-project-dockerfile.sh` that runs inside a real container (same pattern as `test/test-bind-mode.sh`). This test creates a `.yolo/Dockerfile`, stubs `docker compose` (but lets `docker build` run for real), and verifies the base image is built:

```bash
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
```

Move the summary block to after this E2E section (remove the earlier one, keep only one at the end).

**Step 2: Run the full test**

Run: `bash test/test-project-dockerfile.sh`
Expected: All tests pass (unit tests from Task 1 + E2E tests).

**Step 3: Run all tests**

Run: `make test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add test/test-project-dockerfile.sh
git commit -m "test: add E2E test for per-project Dockerfile build"
```

---

### Task 5: Final verification and cleanup

**Step 1: Run full test suite**

Run: `make test`
Expected: All tests pass.

**Step 2: Manual smoke test (optional)**

Create a `.yolo/Dockerfile` in any project directory:
```dockerfile
FROM yolo-base
RUN echo "custom image" > /tmp/custom-marker
```

Run `yolo up test-custom` and verify:
- "Building base image" appears in output
- "Base image ready" appears
- Container starts with the custom image

**Step 3: Clean up design doc — replace with final plan**

The `docs/plans/2026-03-03-per-project-dockerfile-design.md` file already contains this plan.

**Step 4: Commit everything**

```bash
git add -A
git commit -m "docs: finalize per-project Dockerfile implementation plan"
```
