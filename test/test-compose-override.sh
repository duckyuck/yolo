#!/usr/bin/env bash
# Test user compose override detection (collect_user_overrides).
# Verifies global and per-project override files are picked up.
# Usage: ./test/test-compose-override.sh
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

# Extract collect_user_overrides from the yolo script so we can test it directly
eval "$(sed -n '/^collect_user_overrides()/,/^}/p' "$(dirname "$0")/../yolo")"

# ─── Test cases ──────────────────────────────────────────────────────────────

echo -e "\n${BOLD}User compose overrides${RESET}"

# 1. No override files → empty output
result=$(collect_user_overrides "$TMPDIR" "myproject")
if [ -z "$result" ]; then
    pass "No overrides when no files exist"
else
    fail "No overrides when no files exist — got: $result"
fi

# 2. Global override only
cat > "$TMPDIR/compose.override.yml" << 'EOF'
services:
  claude:
    ports:
      - "3000:3000"
EOF
result=$(collect_user_overrides "$TMPDIR" "myproject")
if [[ "$result" == "$TMPDIR/compose.override.yml" ]]; then
    pass "Global override detected"
else
    fail "Global override detected — got: $result"
fi
rm "$TMPDIR/compose.override.yml"

# 3. Per-project override only
mkdir -p "$TMPDIR/myproject"
cat > "$TMPDIR/myproject/compose.override.yml" << 'EOF'
services:
  claude:
    ports:
      - "8080:8080"
EOF
result=$(collect_user_overrides "$TMPDIR" "myproject")
if [[ "$result" == "$TMPDIR/myproject/compose.override.yml" ]]; then
    pass "Per-project override detected"
else
    fail "Per-project override detected — got: $result"
fi

# 4. Both global and per-project → both returned, global first
cat > "$TMPDIR/compose.override.yml" << 'EOF'
services:
  claude:
    ports:
      - "3000:3000"
EOF
readarray -t overrides <<< "$(collect_user_overrides "$TMPDIR" "myproject")"
if [ "${#overrides[@]}" -eq 2 ] \
   && [[ "${overrides[0]}" == "$TMPDIR/compose.override.yml" ]] \
   && [[ "${overrides[1]}" == "$TMPDIR/myproject/compose.override.yml" ]]; then
    pass "Both overrides returned in correct order"
else
    fail "Both overrides returned in correct order — got: $(printf '%s, ' "${overrides[@]}")"
fi

# 5. Different project → only global (not the other project's override)
result=$(collect_user_overrides "$TMPDIR" "otherproject")
if [[ "$result" == "$TMPDIR/compose.override.yml" ]]; then
    pass "Other project only gets global override"
else
    fail "Other project only gets global override — got: $result"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
