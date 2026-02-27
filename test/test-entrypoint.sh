#!/usr/bin/env bash
# Test the container entrypoint end-to-end.
# Builds the real yolo image, starts a container with mock SSH keys and Claude
# config, and verifies that the entrypoint correctly sets up:
#   - SSH agent with keys loaded, private keys deleted from disk
#   - macOS SSH config options filtered out
#   - Claude config copied with host→container path transforms
#   - .claude.json project keys restored to host paths, trust accepted
#   - Tmux session running
# Usage: ./test/test-entrypoint.sh
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_IMAGE="yolo-test-entrypoint-$$"
CONTAINER=""

cleanup() {
    [ -n "$CONTAINER" ] && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker rmi "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

# ─── Build image ──────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Entrypoint setup${RESET}"

if [ -t 1 ]; then
    printf "  ${DIM}Building test image...${RESET}"
fi
if ! docker build -q -t "$TEST_IMAGE" \
        --build-arg HOST_UID="$(id -u)" \
        --build-arg HOST_GID="$(id -g)" \
        "$SCRIPT_DIR" >/dev/null 2>&1; then
    [ -t 1 ] && printf "\r\033[K"
    fail "Failed to build test image"
    echo -e "\n${RED}${BOLD}1 test(s) failed${RESET}"
    exit 1
fi
[ -t 1 ] && printf "\r\033[K"

# ─── Prepare mock host files ─────────────────────────────────────────────────

MOCK_HOME="$TMPDIR/mock-host-home"
MOCK_SSH="$MOCK_HOME/.ssh"
MOCK_CLAUDE="$MOCK_HOME/.claude"
WORKDIR="$TMPDIR/workdir"
mkdir -p "$MOCK_SSH" "$MOCK_CLAUDE" "$WORKDIR"

# Generate a test SSH key (unencrypted)
ssh-keygen -t ed25519 -f "$MOCK_SSH/id_ed25519" -N "" -q

# Add known_hosts
echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" \
    > "$MOCK_SSH/known_hosts"

# SSH config with macOS-only options that should be filtered
cat > "$MOCK_SSH/config" << 'SSHCONF'
Host github.com
    HostName github.com
    User git
    UseKeychain yes
    IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    IdentityFile ~/.ssh/id_ed25519
Host *
    AddKeysToAgent yes
SSHCONF

# Claude config directory with a settings file containing host paths
cat > "$MOCK_CLAUDE/settings.json" << SETTINGS
{"preferredModel": "opus", "workdir": "$MOCK_HOME/projects"}
SETTINGS

# .claude.json with project trust keyed to host paths
cat > "$MOCK_HOME/.claude.json" << CLAUDEJSON
{
    "projects": {
        "$MOCK_HOME/my-project": {"hasTrustDialogAccepted": true}
    },
    "numStartups": 5
}
CLAUDEJSON

# Fake credentials file (mounted read-write in real usage)
echo '{}' > "$MOCK_CLAUDE/.credentials.json"

# ─── Start container with real entrypoint ─────────────────────────────────────

CONTAINER=$(docker run -d \
    -v "$MOCK_SSH:/mnt/host-ssh:ro" \
    -v "$MOCK_CLAUDE:/mnt/host-claude:ro" \
    -v "$MOCK_HOME/.claude.json:/mnt/host-claude.json:ro" \
    -v "$MOCK_CLAUDE/.credentials.json:/home/claude/.claude/.credentials.json" \
    -v "$WORKDIR:$WORKDIR" \
    -e WORKDIR="$WORKDIR" \
    -e SESSION_NAME="test-ep" \
    -e HOST_HOME="$MOCK_HOME" \
    -e CLAUDE_MODEL="claude-opus-4-6" \
    "$TEST_IMAGE"
)

# Wait for entrypoint to finish setup (tmux session appears when ready)
READY=false
for i in $(seq 1 30); do
    if docker exec "$CONTAINER" tmux has-session -t "test-ep" 2>/dev/null; then
        READY=true
        break
    fi
    sleep 0.5
done

if [ "$READY" != "true" ]; then
    fail "Container entrypoint did not start tmux session within 15s"
    echo -e "  ${DIM}Container logs:${RESET}"
    docker logs "$CONTAINER" 2>&1 | tail -20 | sed 's/^/    /'
    echo -e "\n${RED}${BOLD}$((FAILURES)) test(s) failed${RESET}"
    exit 1
fi

# ─── SSH agent ────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}SSH setup${RESET}"

# Keys loaded into agent
AGENT_KEYS=$(docker exec "$CONTAINER" bash -c 'source ~/.ssh/agent.env && ssh-add -l 2>&1') || true
if [[ "${AGENT_KEYS,,}" == *"ed25519"* ]]; then
    pass "SSH key loaded into agent"
else
    fail "SSH key not in agent — got: $AGENT_KEYS"
fi

# Private key deleted from disk
if docker exec "$CONTAINER" test -f /home/claude/.ssh/id_ed25519 2>/dev/null; then
    fail "Private key should be deleted from disk"
else
    pass "Private key deleted from disk"
fi

# Public key still on disk
if docker exec "$CONTAINER" test -f /home/claude/.ssh/id_ed25519.pub 2>/dev/null; then
    pass "Public key kept on disk"
else
    fail "Public key should remain on disk"
fi

# known_hosts copied
if docker exec "$CONTAINER" test -f /home/claude/.ssh/known_hosts 2>/dev/null; then
    pass "known_hosts copied"
else
    fail "known_hosts should be copied"
fi

# SSH config filtered (no UseKeychain, no 1password IdentityAgent)
SSH_CONFIG=$(docker exec "$CONTAINER" cat /home/claude/.ssh/config 2>/dev/null) || true
if [[ "$SSH_CONFIG" == *"UseKeychain"* ]]; then
    fail "SSH config should filter UseKeychain"
else
    pass "macOS UseKeychain filtered from SSH config"
fi

if [[ "$SSH_CONFIG" == *"1password"* ]] || [[ "$SSH_CONFIG" == *"Group Containers"* ]]; then
    fail "SSH config should filter 1password IdentityAgent"
else
    pass "macOS 1password IdentityAgent filtered from SSH config"
fi

# Non-macOS options preserved
if [[ "$SSH_CONFIG" == *"AddKeysToAgent"* ]]; then
    pass "Non-macOS SSH options preserved"
else
    fail "Non-macOS SSH options should be preserved"
fi

# Agent env file written
if docker exec "$CONTAINER" test -f /home/claude/.ssh/agent.env 2>/dev/null; then
    pass "Agent env file written"
else
    fail "Agent env file should exist"
fi

# ─── Claude config ────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Claude config${RESET}"

# Settings file copied with path transforms
SETTINGS=$(docker exec "$CONTAINER" cat /home/claude/.claude/settings.json 2>/dev/null) || true
if [[ "$SETTINGS" == *"/home/claude/projects"* ]]; then
    pass "Config paths transformed to container paths"
else
    fail "Config paths should be transformed — got: $SETTINGS"
fi

if [[ "$SETTINGS" == *"$MOCK_HOME"* ]]; then
    fail "Config should not contain host paths"
else
    pass "Host paths removed from config"
fi

# ─── .claude.json ─────────────────────────────────────────────────────────────

echo -e "\n${BOLD}.claude.json${RESET}"

CLAUDE_JSON=$(docker exec "$CONTAINER" cat /home/claude/.claude.json 2>/dev/null) || true

# installMethod set to native
if echo "$CLAUDE_JSON" | jq -e '.installMethod == "native"' >/dev/null 2>&1; then
    pass "installMethod set to native"
else
    fail "installMethod should be native — got: $(echo "$CLAUDE_JSON" | jq '.installMethod')"
fi

# skipDangerousModePermissionPrompt set
if echo "$CLAUDE_JSON" | jq -e '.skipDangerousModePermissionPrompt == true' >/dev/null 2>&1; then
    pass "skipDangerousModePermissionPrompt set"
else
    fail "skipDangerousModePermissionPrompt should be true"
fi

# Project keys restored to host paths (not /home/claude)
PROJECT_KEYS=$(echo "$CLAUDE_JSON" | jq -r '.projects | keys[]' 2>/dev/null) || true
if [[ "$PROJECT_KEYS" == *"$MOCK_HOME"* ]]; then
    pass "Project keys use host paths"
else
    fail "Project keys should use host paths — got: $PROJECT_KEYS"
fi

if [[ "$PROJECT_KEYS" == */home/claude* ]]; then
    fail "Project keys should not contain container paths"
else
    pass "No container paths in project keys"
fi

# WORKDIR trust accepted
if echo "$CLAUDE_JSON" | jq -e --arg w "$WORKDIR" '.projects[$w].hasTrustDialogAccepted == true' >/dev/null 2>&1; then
    pass "WORKDIR trust accepted"
else
    fail "WORKDIR should have trust accepted — got: $(echo "$CLAUDE_JSON" | jq --arg w "$WORKDIR" '.projects[$w]')"
fi

# ─── Tmux ─────────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Tmux session${RESET}"

# Session exists with correct name
if docker exec "$CONTAINER" tmux has-session -t "test-ep" 2>/dev/null; then
    pass "Tmux session 'test-ep' running"
else
    fail "Tmux session 'test-ep' should be running"
fi

# Window named 'claude'
WINDOWS=$(docker exec "$CONTAINER" tmux list-windows -t "test-ep" -F '#{window_name}' 2>/dev/null) || true
if [[ "$WINDOWS" == *"claude"* ]]; then
    pass "Tmux window named 'claude'"
else
    fail "Tmux window should be named 'claude' — got: $WINDOWS"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
