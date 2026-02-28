#!/usr/bin/env bash
# Test OAuth credential extraction and container auth checking.
# Verifies:
#   - extract_keychain_credentials uses whichever source has the later expiresAt
#   - CREDENTIALS_REFRESHED flag set when the file token changes
#   - is_token_expired detects expired tokens
#   - require_auth attempts host-side refresh when token is expired
#   - check_container_auth detects stale auth and restarts tmux session
# Usage: ./test/test-auth.sh
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

# Epoch-ms helpers
NOW_MS=$(( $(date +%s) * 1000 ))
FUTURE_MS=$(( NOW_MS + 3600000 ))   # +1 hour
PAST_MS=$(( NOW_MS - 3600000 ))     # -1 hour
FAR_FUTURE_MS=$(( NOW_MS + 7200000 )) # +2 hours

# ─── extract_keychain_credentials tests ────────────────────────────────────────

echo -e "\n${BOLD}extract_keychain_credentials: expiry-aware merge${RESET}"

# Build a minimal PATH with just essential commands (no system security)
ESSENTIAL_BIN="$TMPDIR/essential-bin"
mkdir -p "$ESSENTIAL_BIN"
for cmd in jq mkdir cat sed dirname basename echo bash command date; do
    real=$(command -v "$cmd" 2>/dev/null) || true
    [ -n "$real" ] && ln -sf "$real" "$ESSENTIAL_BIN/$cmd"
done

# Helper: run extract_keychain_credentials with mocked environment.
# Prints CREDENTIALS_REFRESHED value to stdout. Preserves the function's exit code.
run_extract() {
    local mock_bin="$1"
    local yolo_host_home="$2"

    (
        export YOLO_HOST_HOME="$yolo_host_home"
        export PATH="$mock_bin:$ESSENTIAL_BIN"

        eval "$(sed -n '/^extract_keychain_credentials()/,/^}/p' "$SCRIPT_DIR/yolo")"
        CREDENTIALS_REFRESHED=false
        local rc=0
        extract_keychain_credentials || rc=$?
        echo "$CREDENTIALS_REFRESHED"
        exit $rc
    )
}

# 1. Keychain has later expiresAt → overwrites file
MOCK1="$TMPDIR/mock1/bin"
MOCK1_HOME="$TMPDIR/mock1/home"
mkdir -p "$MOCK1" "$MOCK1_HOME/.claude"

echo "{\"claudeAiOauth\":{\"accessToken\":\"old-file-token\",\"expiresAt\":$PAST_MS}}" \
    > "$MOCK1_HOME/.claude/.credentials.json"

cat > "$MOCK1/security" << MOCK
#!/usr/bin/env bash
echo '{"claudeAiOauth":{"accessToken":"keychain-token","expiresAt":$FUTURE_MS}}'
MOCK
chmod +x "$MOCK1/security"

REFRESHED=$(run_extract "$MOCK1" "$MOCK1_HOME")
TOKEN=$(jq -r '.claudeAiOauth.accessToken' "$MOCK1_HOME/.claude/.credentials.json" 2>/dev/null)
if [ "$TOKEN" = "keychain-token" ]; then
    pass "Keychain token used when it has later expiresAt"
else
    fail "Expected keychain-token, got: $TOKEN"
fi
if [ "$REFRESHED" = "true" ]; then
    pass "CREDENTIALS_REFRESHED=true when file token replaced"
else
    fail "Expected CREDENTIALS_REFRESHED=true, got: $REFRESHED"
fi

# 2. File has later expiresAt → keeps file (doesn't overwrite with older Keychain token)
MOCK2="$TMPDIR/mock2/bin"
MOCK2_HOME="$TMPDIR/mock2/home"
mkdir -p "$MOCK2" "$MOCK2_HOME/.claude"

echo "{\"claudeAiOauth\":{\"accessToken\":\"fresh-file-token\",\"expiresAt\":$FAR_FUTURE_MS}}" \
    > "$MOCK2_HOME/.claude/.credentials.json"

cat > "$MOCK2/security" << MOCK
#!/usr/bin/env bash
echo '{"claudeAiOauth":{"accessToken":"older-keychain-token","expiresAt":$FUTURE_MS}}'
MOCK
chmod +x "$MOCK2/security"

REFRESHED=$(run_extract "$MOCK2" "$MOCK2_HOME")
TOKEN=$(jq -r '.claudeAiOauth.accessToken' "$MOCK2_HOME/.claude/.credentials.json" 2>/dev/null)
if [ "$TOKEN" = "fresh-file-token" ]; then
    pass "File token preserved when it has later expiresAt"
else
    fail "Expected fresh-file-token, got: $TOKEN"
fi
if [ "$REFRESHED" = "false" ]; then
    pass "CREDENTIALS_REFRESHED=false when file kept"
else
    fail "Expected CREDENTIALS_REFRESHED=false, got: $REFRESHED"
fi

# 3. Same token in both → no refresh flag
MOCK3="$TMPDIR/mock3/bin"
MOCK3_HOME="$TMPDIR/mock3/home"
mkdir -p "$MOCK3" "$MOCK3_HOME/.claude"

echo "{\"claudeAiOauth\":{\"accessToken\":\"same-token\",\"expiresAt\":$FUTURE_MS}}" \
    > "$MOCK3_HOME/.claude/.credentials.json"

cat > "$MOCK3/security" << MOCK
#!/usr/bin/env bash
echo '{"claudeAiOauth":{"accessToken":"same-token","expiresAt":$FUTURE_MS}}'
MOCK
chmod +x "$MOCK3/security"

REFRESHED=$(run_extract "$MOCK3" "$MOCK3_HOME")
if [ "$REFRESHED" = "false" ]; then
    pass "CREDENTIALS_REFRESHED=false when tokens identical"
else
    fail "Expected CREDENTIALS_REFRESHED=false, got: $REFRESHED"
fi

# 4. Keychain unavailable → falls back to existing file
MOCK4="$TMPDIR/mock4/bin"
MOCK4_HOME="$TMPDIR/mock4/home"
mkdir -p "$MOCK4" "$MOCK4_HOME/.claude"

echo "{\"claudeAiOauth\":{\"accessToken\":\"file-only-token\",\"expiresAt\":$FUTURE_MS}}" \
    > "$MOCK4_HOME/.claude/.credentials.json"

REFRESHED=$(run_extract "$MOCK4" "$MOCK4_HOME")
TOKEN=$(jq -r '.claudeAiOauth.accessToken' "$MOCK4_HOME/.claude/.credentials.json" 2>/dev/null)
if [ "$TOKEN" = "file-only-token" ]; then
    pass "Falls back to existing file when Keychain unavailable"
else
    fail "Expected file-only-token, got: $TOKEN"
fi

# 5. No Keychain, no file → returns failure
MOCK5="$TMPDIR/mock5/bin"
MOCK5_HOME="$TMPDIR/mock5/home"
mkdir -p "$MOCK5" "$MOCK5_HOME/.claude"

EXTRACT_RC=0
run_extract "$MOCK5" "$MOCK5_HOME" >/dev/null 2>&1 || EXTRACT_RC=$?
if [ "$EXTRACT_RC" -ne 0 ]; then
    pass "Returns failure when no credentials available"
else
    fail "Should fail when no Keychain and no credentials file"
fi

# 6. Keychain returns invalid JSON → falls back to file
MOCK6="$TMPDIR/mock6/bin"
MOCK6_HOME="$TMPDIR/mock6/home"
mkdir -p "$MOCK6" "$MOCK6_HOME/.claude"

echo "{\"claudeAiOauth\":{\"accessToken\":\"fallback-token\",\"expiresAt\":$FUTURE_MS}}" \
    > "$MOCK6_HOME/.claude/.credentials.json"

cat > "$MOCK6/security" << 'MOCK'
#!/usr/bin/env bash
echo 'not-json'
MOCK
chmod +x "$MOCK6/security"

REFRESHED=$(run_extract "$MOCK6" "$MOCK6_HOME")
TOKEN=$(jq -r '.claudeAiOauth.accessToken' "$MOCK6_HOME/.claude/.credentials.json" 2>/dev/null)
if [ "$TOKEN" = "fallback-token" ]; then
    pass "Falls back to file when Keychain returns invalid JSON"
else
    fail "Expected fallback-token, got: $TOKEN"
fi

# ─── is_token_expired tests ─────────────────────────────────────────────────

echo -e "\n${BOLD}is_token_expired${RESET}"

# Source the function
eval "$(sed -n '/^is_token_expired()/,/^}/p' "$SCRIPT_DIR/yolo")"

# 7. Expired token
EXPIRED_HOME="$TMPDIR/expired-home"
mkdir -p "$EXPIRED_HOME/.claude"
echo "{\"claudeAiOauth\":{\"accessToken\":\"x\",\"expiresAt\":$PAST_MS}}" \
    > "$EXPIRED_HOME/.claude/.credentials.json"

if YOLO_HOST_HOME="$EXPIRED_HOME" is_token_expired; then
    pass "Detects expired token"
else
    fail "Should detect expired token"
fi

# 8. Valid token
VALID_HOME="$TMPDIR/valid-home"
mkdir -p "$VALID_HOME/.claude"
echo "{\"claudeAiOauth\":{\"accessToken\":\"x\",\"expiresAt\":$FUTURE_MS}}" \
    > "$VALID_HOME/.claude/.credentials.json"

if YOLO_HOST_HOME="$VALID_HOME" is_token_expired; then
    fail "Should not flag valid token as expired"
else
    pass "Valid token not flagged as expired"
fi

# ─── check_container_auth tests ─────────────────────────────────────────────
# These need a running container. We reuse the entrypoint test image approach.

TEST_IMAGE="yolo-test-auth-$$"
CONTAINER=""

cleanup_container() {
    [ -n "$CONTAINER" ] && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker rmi "$TEST_IMAGE" >/dev/null 2>&1 || true
}
trap "cleanup_container; rm -rf '$TMPDIR'" EXIT

echo -e "\n${BOLD}check_container_auth: stale auth detection${RESET}"

if [ -t 1 ]; then
    printf "  ${DIM}Building test image...${RESET}"
fi
if ! docker build -q -t "$TEST_IMAGE" \
        --build-arg HOST_UID="$(id -u)" \
        --build-arg HOST_GID="$(id -g)" \
        "$SCRIPT_DIR" >/dev/null 2>&1; then
    [ -t 1 ] && printf "\r\033[K"
    fail "Failed to build test image"
    echo -e "\n${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
[ -t 1 ] && printf "\r\033[K"

MOCK_HOME="$TMPDIR/auth-home"
WORKDIR="$TMPDIR/auth-workdir"
mkdir -p "$MOCK_HOME/.ssh" "$MOCK_HOME/.claude" "$WORKDIR"

ssh-keygen -t ed25519 -f "$MOCK_HOME/.ssh/id_ed25519" -N "" -q

echo '{}' > "$MOCK_HOME/.claude/.credentials.json"
echo '{}' > "$MOCK_HOME/.claude.json"

CONTAINER=$(docker run -d \
    -v "$MOCK_HOME/.ssh:/mnt/host-ssh:ro" \
    -v "$MOCK_HOME/.claude:/mnt/host-claude:ro" \
    -v "$MOCK_HOME/.claude.json:/mnt/host-claude.json:ro" \
    -v "$MOCK_HOME/.claude/.credentials.json:/home/claude/.claude/.credentials.json" \
    -v "$WORKDIR:$WORKDIR" \
    -e WORKDIR="$WORKDIR" \
    -e SESSION_NAME="test-auth" \
    -e HOST_HOME="$MOCK_HOME" \
    -e CLAUDE_MODEL="claude-opus-4-6" \
    "$TEST_IMAGE"
)

READY=false
for i in $(seq 1 30); do
    if docker exec "$CONTAINER" tmux has-session -t "test-auth" 2>/dev/null; then
        READY=true
        break
    fi
    sleep 0.5
done

if [ "$READY" != "true" ]; then
    fail "Container did not start within 15s"
    echo -e "\n${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi

# Kill Claude process in tmux so we have a plain shell for testing
docker exec "$CONTAINER" tmux send-keys -t "test-auth" C-c 2>/dev/null
sleep 0.5
docker exec "$CONTAINER" tmux send-keys -t "test-auth" C-c 2>/dev/null
sleep 0.5
docker exec "$CONTAINER" tmux send-keys -t "test-auth" "clear" Enter 2>/dev/null
sleep 0.5

# Helper: run check_container_auth in a subshell with given env
run_auth_check() {
    local container="$1"
    local session="$2"
    local creds_refreshed="${3:-false}"
    local yolo_host_home="$4"

    (
        unset ANTHROPIC_API_KEY 2>/dev/null || true
        CREDENTIALS_REFRESHED="$creds_refreshed"
        export YOLO_HOST_HOME="$yolo_host_home"

        eval "$(sed -n '/^is_token_expired()/,/^}/p' "$SCRIPT_DIR/yolo")"
        eval "$(sed -n '/^check_container_auth()/,/^}/p' "$SCRIPT_DIR/yolo")"

        BOLD='' DIM='' RESET='' CYAN='' GREEN='' YELLOW='' RED='' BLUE='' MAGENTA=''
        info()    { :; }
        success() { :; }
        warning() { :; }
        export CLAUDE_MODEL="claude-opus-4-6"
        export WORKDIR="$WORKDIR"
        export YOLO_SESSION_BASE=""

        check_container_auth "$container" "$session"
    )
}

# Helper: kill Claude in tmux and get a clean shell
kill_claude_in_pane() {
    docker exec "$CONTAINER" tmux send-keys -t "test-auth" C-c 2>/dev/null
    sleep 0.5
    docker exec "$CONTAINER" tmux send-keys -t "test-auth" C-c 2>/dev/null
    sleep 0.5
    docker exec "$CONTAINER" tmux send-keys -t "test-auth" "clear" Enter 2>/dev/null
    sleep 0.5
}

# Credentials home for check_container_auth tests
CREDS_HOME="$TMPDIR/creds-home"
mkdir -p "$CREDS_HOME/.claude"

# 9. API key users skip auth check
(
    export ANTHROPIC_API_KEY="sk-test-key"
    CREDENTIALS_REFRESHED=true

    eval "$(sed -n '/^is_token_expired()/,/^}/p' "$SCRIPT_DIR/yolo")"
    eval "$(sed -n '/^check_container_auth()/,/^}/p' "$SCRIPT_DIR/yolo")"

    BOLD='' DIM='' RESET='' CYAN='' GREEN='' YELLOW='' RED='' BLUE='' MAGENTA=''
    info()    { :; }
    success() { :; }
    warning() { :; }

    if check_container_auth "$CONTAINER" "test-auth"; then
        pass "Skips auth check for API key users"
    else
        fail "Should skip auth check when ANTHROPIC_API_KEY is set"
    fi
)

# 10. Non-expired token + no refresh + clean pane → no restart
echo "{\"claudeAiOauth\":{\"accessToken\":\"valid\",\"expiresAt\":$FUTURE_MS}}" \
    > "$CREDS_HOME/.claude/.credentials.json"

docker exec "$CONTAINER" tmux send-keys -t "test-auth" "echo 'Claude is running fine'" Enter 2>/dev/null
sleep 0.5

TMUX_CREATED_BEFORE=$(docker exec "$CONTAINER" tmux list-sessions -F '#{session_created}' 2>/dev/null) || true

run_auth_check "$CONTAINER" "test-auth" "false" "$CREDS_HOME"

TMUX_CREATED_AFTER=$(docker exec "$CONTAINER" tmux list-sessions -F '#{session_created}' 2>/dev/null) || true
if [ "$TMUX_CREATED_BEFORE" = "$TMUX_CREATED_AFTER" ]; then
    pass "No restart when token valid and pane clean"
else
    fail "Should not restart when session looks healthy"
fi

# 11. Expired token → triggers restart
echo "{\"claudeAiOauth\":{\"accessToken\":\"expired\",\"expiresAt\":$PAST_MS}}" \
    > "$CREDS_HOME/.claude/.credentials.json"

docker exec "$CONTAINER" tmux send-keys -t "test-auth" "clear && echo 'looks fine'" Enter 2>/dev/null
sleep 0.5

TMUX_CREATED_BEFORE=$(docker exec "$CONTAINER" tmux list-sessions -F '#{session_created}' 2>/dev/null) || true

run_auth_check "$CONTAINER" "test-auth" "false" "$CREDS_HOME"

sleep 1
if docker exec "$CONTAINER" tmux has-session -t "test-auth" 2>/dev/null; then
    TMUX_CREATED_AFTER=$(docker exec "$CONTAINER" tmux list-sessions -F '#{session_created}' 2>/dev/null) || true
    if [ "$TMUX_CREATED_BEFORE" != "$TMUX_CREATED_AFTER" ]; then
        pass "Expired token triggers tmux restart"
    else
        fail "Should restart when token is expired"
    fi
else
    fail "Tmux session should exist after restart"
fi

# 12. CREDENTIALS_REFRESHED=true → triggers restart (even with valid token)
echo "{\"claudeAiOauth\":{\"accessToken\":\"valid\",\"expiresAt\":$FUTURE_MS}}" \
    > "$CREDS_HOME/.claude/.credentials.json"

kill_claude_in_pane
docker exec "$CONTAINER" tmux send-keys -t "test-auth" "echo 'looks fine'" Enter 2>/dev/null
sleep 0.5

TMUX_CREATED_BEFORE=$(docker exec "$CONTAINER" tmux list-sessions -F '#{session_created}' 2>/dev/null) || true

run_auth_check "$CONTAINER" "test-auth" "true" "$CREDS_HOME"

sleep 1
if docker exec "$CONTAINER" tmux has-session -t "test-auth" 2>/dev/null; then
    TMUX_CREATED_AFTER=$(docker exec "$CONTAINER" tmux list-sessions -F '#{session_created}' 2>/dev/null) || true
    if [ "$TMUX_CREATED_BEFORE" != "$TMUX_CREATED_AFTER" ]; then
        pass "CREDENTIALS_REFRESHED=true triggers tmux restart"
    else
        fail "Should restart when credentials were refreshed"
    fi
else
    fail "Tmux session should exist after restart"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
