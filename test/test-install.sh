#!/usr/bin/env bash
# Test the yolo install flow inside a Docker container.
# Verifies: file layout, hooks, permissions, prereq checks, auth error message.
# Usage: ./test/test-install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

BOLD='' DIM='' RESET='' GREEN='' RED='' CYAN='' DIM=''
if [ -t 1 ]; then
    BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
    GREEN='\033[32m' RED='\033[31m' CYAN='\033[36m'
fi

pass() { echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; FAILURES=$((FAILURES + 1)); }
cleanup() {
    rm -f "$SCRIPT_DIR/yolo-test.tar.gz" "$SCRIPT_DIR/install-local.sh"
    docker rmi yolo-install-test >/dev/null 2>&1 || true
}

FAILURES=0
trap cleanup EXIT

cd "$PROJECT_DIR"

# ─── Step 1: Build a local tarball mimicking the release format ───────────────

echo -e "\n${BOLD}Building test tarball${RESET}"

VERSION=$(grep '^YOLO_VERSION=' yolo | head -1 | sed 's/YOLO_VERSION="//' | sed 's/"//')
TEMP_DIR=$(mktemp -d)

BUNDLE_DIR="$TEMP_DIR/yolo-${VERSION}"
mkdir -p "$BUNDLE_DIR/hooks"
cp yolo docker-compose.yml Dockerfile entrypoint.sh tmux.conf "$BUNDLE_DIR/"
cp hooks/*.sh "$BUNDLE_DIR/hooks/"
chmod +x "$BUNDLE_DIR/yolo" "$BUNDLE_DIR/entrypoint.sh" "$BUNDLE_DIR/hooks/"*.sh

tar czf "$SCRIPT_DIR/yolo-test.tar.gz" -C "$TEMP_DIR" "yolo-${VERSION}"
rm -rf "$TEMP_DIR"
pass "Tarball v${VERSION}"

# ─── Step 2: Create a minimal local installer ────────────────────────────────

cat > "$SCRIPT_DIR/install-local.sh" << ENDOFINSTALLER
#!/usr/bin/env bash
set -euo pipefail
YOLO_HOME="\${YOLO_HOME:-\$HOME/.yolo}"
LATEST_TAG="$VERSION"

check_prereqs() {
    local missing=()
    [ "\${BASH_VERSINFO[0]}" -lt 4 ] && missing+=("bash 4+")
    ! command -v docker >/dev/null 2>&1 && missing+=("docker")
    ! command -v git >/dev/null 2>&1 && missing+=("git")
    ! command -v curl >/dev/null 2>&1 && missing+=("curl")
    ! command -v jq >/dev/null 2>&1 && missing+=("jq — brew install jq / apt install jq")
    if [ \${#missing[@]} -gt 0 ]; then
        echo "Missing prerequisites:" >&2
        for m in "\${missing[@]}"; do echo "  - \$m" >&2; done
        exit 1
    fi
}

check_prereqs
TEMP_DIR=\$(mktemp -d)
trap "rm -rf '\$TEMP_DIR'" EXIT
tar xzf /tmp/yolo-test.tar.gz -C "\$TEMP_DIR"
mkdir -p "\$YOLO_HOME/bin" "\$YOLO_HOME/lib" "\$YOLO_HOME/lib/hooks"
cp "\$TEMP_DIR/yolo-\${LATEST_TAG}/yolo" "\$YOLO_HOME/bin/yolo"
chmod +x "\$YOLO_HOME/bin/yolo"
for f in docker-compose.yml Dockerfile entrypoint.sh tmux.conf; do
    cp "\$TEMP_DIR/yolo-\${LATEST_TAG}/\$f" "\$YOLO_HOME/lib/\$f"
done
cp "\$TEMP_DIR/yolo-\${LATEST_TAG}/hooks/"*.sh "\$YOLO_HOME/lib/hooks/" 2>/dev/null || true
chmod +x "\$YOLO_HOME/lib/hooks/"*.sh 2>/dev/null || true
echo "\$LATEST_TAG" > "\$YOLO_HOME/version"
[ -f "\$HOME/.bashrc" ] && ! grep -qF ".yolo/bin" "\$HOME/.bashrc" 2>/dev/null && {
    echo "" >> "\$HOME/.bashrc"
    echo "# yolo" >> "\$HOME/.bashrc"
    echo "export PATH=\"\$YOLO_HOME/bin:\\\$PATH\"" >> "\$HOME/.bashrc"
}
echo "Installed yolo v\${LATEST_TAG}"
ENDOFINSTALLER
chmod +x "$SCRIPT_DIR/install-local.sh"

# ─── Step 3: Build the Docker test image ──────────────────────────────────────

echo -e "\n${BOLD}Building test container${RESET}"

docker build -q -t yolo-install-test -f - "$SCRIPT_DIR" >/dev/null << 'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq ca-certificates docker.io \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash testuser && touch /home/testuser/.bashrc
USER testuser
WORKDIR /home/testuser
COPY --chown=testuser:testuser yolo-test.tar.gz /tmp/yolo-test.tar.gz
COPY --chown=testuser:testuser install-local.sh /tmp/install.sh
DOCKERFILE
pass "Image built"

# ─── Step 4: Run install and verify file layout ──────────────────────────────

echo -e "\n${BOLD}Verifying installed layout${RESET}"

VERIFY_OUTPUT=$(docker run --rm yolo-install-test bash -c '
    bash /tmp/install.sh 2>&1

    echo "=== FILES ==="
    for f in \
        bin/yolo \
        lib/docker-compose.yml \
        lib/Dockerfile \
        lib/entrypoint.sh \
        lib/tmux.conf \
        lib/hooks/worktree-create.sh \
        lib/hooks/worktree-remove.sh \
        version; do
        [ -f "$HOME/.yolo/$f" ] && echo "OK:$f" || echo "MISSING:$f"
    done

    echo "=== EXECUTABLE ==="
    for f in bin/yolo lib/hooks/worktree-create.sh lib/hooks/worktree-remove.sh; do
        [ -x "$HOME/.yolo/$f" ] && echo "X:$f" || echo "NX:$f"
    done

    echo "=== VERSION ==="
    cat "$HOME/.yolo/version"

    echo "=== BASHRC ==="
    grep -q ".yolo/bin" "$HOME/.bashrc" && echo "PATH_OK" || echo "PATH_MISSING"
' 2>&1)

while IFS= read -r line; do
    case "$line" in
        OK:*)           pass "${line#OK:}" ;;
        MISSING:*)      fail "Missing: ${line#MISSING:}" ;;
        X:*)            pass "${line#X:} is executable" ;;
        NX:*)           fail "${line#NX:} not executable" ;;
        PATH_OK)        pass "PATH added to .bashrc" ;;
        PATH_MISSING)   fail "PATH not in .bashrc" ;;
        "=== "*)        ;;
        "$VERSION")     pass "Version file: $VERSION" ;;
        Installed*)     ;;
        tar:*)          ;; # macOS xattr warnings
        *)              [ -n "$line" ] && echo "    $line" ;;
    esac
done <<< "$VERIFY_OUTPUT"

# ─── Step 5: Prereq check catches missing jq ─────────────────────────────────

echo -e "\n${BOLD}Prereq check: missing jq${RESET}"

JQ_CHECK=$(docker run --rm --user root yolo-install-test bash -c '
    mv /usr/bin/jq /usr/bin/jq.bak 2>/dev/null
    su testuser -c "bash /tmp/install.sh" 2>&1 || true
' 2>&1) || true

if echo "$JQ_CHECK" | grep -q "jq"; then
    pass "Detects missing jq"
else
    fail "Did NOT detect missing jq"
fi

# ─── Step 6: Auth error message (needs docker socket) ────────────────────────

echo -e "\n${BOLD}Auth error message${RESET}"

if [ -S /var/run/docker.sock ]; then
    # Run as root because Docker Desktop maps socket to root:root inside container
    AUTH_CHECK=$(docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --user root \
        yolo-install-test bash -c '
        export HOME=/root
        bash /tmp/install.sh >/dev/null 2>&1
        export PATH="$HOME/.yolo/bin:$PATH"
        mkdir -p /tmp/test-repo && cd /tmp/test-repo
        git config --global user.email "test@test.com"
        git config --global user.name "Test"
        git init -q && git commit --allow-empty -m "init" -q
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
        yolo up test-session 2>&1 || true
    ' 2>&1) || true

    if echo "$AUTH_CHECK" | grep -q "ANTHROPIC_API_KEY"; then
        pass "Mentions ANTHROPIC_API_KEY"
    else
        fail "Missing ANTHROPIC_API_KEY"
    fi

    if echo "$AUTH_CHECK" | grep -q "Max/Pro"; then
        pass "Mentions Max/Pro subscribers"
    else
        fail "Missing Max/Pro mention"
    fi

    if echo "$AUTH_CHECK" | grep -q "claude auth login"; then
        pass "Mentions 'claude auth login'"
    else
        fail "Missing 'claude auth login'"
    fi
else
    echo -e "  ${DIM}Skipped — no docker socket${RESET}"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
