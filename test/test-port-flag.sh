#!/usr/bin/env bash
# Test --port flag generates correct compose override entries.
# Usage: ./test/test-port-flag.sh
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

# Extract generate_compose_override from the yolo script
eval "$(sed -n '/^generate_compose_override()/,/^}/p' "$(dirname "$0")/../yolo")"

# ─── Test cases ──────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Port flag override generation${RESET}"

# 1. No ports → no ports section
PORTS=()
OVERRIDE="$TMPDIR/no-ports.yml"
generate_compose_override "$OVERRIDE" "/host:/container"
if ! grep -q "ports:" "$OVERRIDE"; then
    pass "No ports section when no ports specified"
else
    fail "No ports section when no ports specified"
fi

# 2. Single port
PORTS=("3000")
OVERRIDE="$TMPDIR/single-port.yml"
generate_compose_override "$OVERRIDE" "/host:/container"
if grep -q '"3000:3000"' "$OVERRIDE"; then
    pass "Single port mapping"
else
    fail "Single port mapping — got: $(cat "$OVERRIDE")"
fi

# 3. Port range
PORTS=("3000-9999")
OVERRIDE="$TMPDIR/port-range.yml"
generate_compose_override "$OVERRIDE" "/host:/container"
if grep -q '"3000-9999:3000-9999"' "$OVERRIDE"; then
    pass "Port range mapping"
else
    fail "Port range mapping — got: $(cat "$OVERRIDE")"
fi

# 4. Multiple ports
PORTS=("3000" "8080")
OVERRIDE="$TMPDIR/multi-port.yml"
generate_compose_override "$OVERRIDE" "/host:/container"
if grep -q '"3000:3000"' "$OVERRIDE" && grep -q '"8080:8080"' "$OVERRIDE"; then
    pass "Multiple port mappings"
else
    fail "Multiple port mappings — got: $(cat "$OVERRIDE")"
fi

# 5. Ports don't interfere with volumes
PORTS=("3000")
OVERRIDE="$TMPDIR/volumes-intact.yml"
generate_compose_override "$OVERRIDE" "/host:/container" "/other:/path"
if grep -q '/host:/container' "$OVERRIDE" && grep -q '/other:/path' "$OVERRIDE"; then
    pass "Volumes still present alongside ports"
else
    fail "Volumes still present alongside ports — got: $(cat "$OVERRIDE")"
fi

# 6. SSH_AUTH_SOCK added when SSH_AGENT_FORWARDED=true
PORTS=()
SSH_AGENT_FORWARDED=true
OVERRIDE="$TMPDIR/ssh-forwarded.yml"
generate_compose_override "$OVERRIDE" "/host:/container"
if grep -q 'SSH_AUTH_SOCK' "$OVERRIDE" && grep -q '/run/host-services/ssh-auth.sock' "$OVERRIDE"; then
    pass "SSH_AUTH_SOCK env var added when agent forwarded"
else
    fail "SSH_AUTH_SOCK env var added when agent forwarded — got: $(cat "$OVERRIDE")"
fi

# 7. SSH_AUTH_SOCK not added when SSH_AGENT_FORWARDED=false
SSH_AGENT_FORWARDED=false
OVERRIDE="$TMPDIR/ssh-not-forwarded.yml"
generate_compose_override "$OVERRIDE" "/host:/container"
if ! grep -q 'SSH_AUTH_SOCK' "$OVERRIDE"; then
    pass "No SSH_AUTH_SOCK when agent not forwarded"
else
    fail "No SSH_AUTH_SOCK when agent not forwarded — got: $(cat "$OVERRIDE")"
fi

# ─── .yolo/ports file parsing ────────────────────────────────────────────────

echo -e "\n${BOLD}.yolo/ports file parsing${RESET}"

# Helper: parse a ports file using the same logic as yolo
parse_ports() {
    local ports_file="$1"
    local PORTS=()
    while IFS= read -r port_line || [ -n "$port_line" ]; do
        port_line="${port_line%%#*}"
        port_line="${port_line%"${port_line##*[![:space:]]}"}"
        port_line="${port_line#"${port_line%%[![:space:]]*}"}"
        [ -z "$port_line" ] && continue
        PORTS+=("$port_line")
    done < "$ports_file"
    printf '%s\n' "${PORTS[@]}"
}

# 8. Basic port list
cat > "$TMPDIR/ports" <<'EOF'
4000
4001
5100
EOF
result=$(parse_ports "$TMPDIR/ports")
expected=$'4000\n4001\n5100'
if [ "$result" = "$expected" ]; then
    pass "Basic port list parsed"
else
    fail "Basic port list — got: $result"
fi

# 9. Comments and blank lines skipped
cat > "$TMPDIR/ports" <<'EOF'
# Ory tunnels
4000
4001

# Frontend
5100
5101
EOF
result=$(parse_ports "$TMPDIR/ports")
expected=$'4000\n4001\n5100\n5101'
if [ "$result" = "$expected" ]; then
    pass "Comments and blank lines skipped"
else
    fail "Comments and blank lines — got: $result"
fi

# 10. Port ranges
cat > "$TMPDIR/ports" <<'EOF'
3000-3999
8080
EOF
result=$(parse_ports "$TMPDIR/ports")
expected=$'3000-3999\n8080'
if [ "$result" = "$expected" ]; then
    pass "Port ranges preserved"
else
    fail "Port ranges — got: $result"
fi

# 11. Inline comments stripped
cat > "$TMPDIR/ports" <<'EOF'
5100  # buyer frontend
5101  # supplier frontend
EOF
result=$(parse_ports "$TMPDIR/ports")
expected=$'5100\n5101'
if [ "$result" = "$expected" ]; then
    pass "Inline comments stripped"
else
    fail "Inline comments — got: $result"
fi

# 12. Leading/trailing whitespace trimmed
printf '  4000  \n\t5100\t\n' > "$TMPDIR/ports"
result=$(parse_ports "$TMPDIR/ports")
expected=$'4000\n5100'
if [ "$result" = "$expected" ]; then
    pass "Whitespace trimmed"
else
    fail "Whitespace trimmed — got: $result"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
