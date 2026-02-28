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

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
