#!/usr/bin/env bash
# Test user compose override detection (collect_user_overrides).
# Verifies repo-local, global, and per-project override files are picked up.
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

# Simulated directories: $TMPDIR/yolo_home = ~/.yolo, $TMPDIR/repo = project dir
YOLO_HOME="$TMPDIR/yolo_home"
REPO_DIR="$TMPDIR/repo"
mkdir -p "$YOLO_HOME" "$REPO_DIR"

# ─── Test cases ──────────────────────────────────────────────────────────────

echo -e "\n${BOLD}User compose overrides${RESET}"

# 1. No override files → empty output
result=$(collect_user_overrides "$YOLO_HOME" "myproject" "$REPO_DIR")
if [ -z "$result" ]; then
    pass "No overrides when no files exist"
else
    fail "No overrides when no files exist — got: $result"
fi

# 2. Global override only
cat > "$YOLO_HOME/compose.override.yml" << 'EOF'
services:
  claude:
    ports:
      - "3000:3000"
EOF
result=$(collect_user_overrides "$YOLO_HOME" "myproject" "$REPO_DIR")
if [[ "$result" == "$YOLO_HOME/compose.override.yml" ]]; then
    pass "Global override detected"
else
    fail "Global override detected — got: $result"
fi
rm "$YOLO_HOME/compose.override.yml"

# 3. Per-project override only
mkdir -p "$YOLO_HOME/myproject"
cat > "$YOLO_HOME/myproject/compose.override.yml" << 'EOF'
services:
  claude:
    ports:
      - "8080:8080"
EOF
result=$(collect_user_overrides "$YOLO_HOME" "myproject" "$REPO_DIR")
if [[ "$result" == "$YOLO_HOME/myproject/compose.override.yml" ]]; then
    pass "Per-project override detected"
else
    fail "Per-project override detected — got: $result"
fi

# 4. Both global and per-project → both returned, global first
cat > "$YOLO_HOME/compose.override.yml" << 'EOF'
services:
  claude:
    ports:
      - "3000:3000"
EOF
readarray -t overrides <<< "$(collect_user_overrides "$YOLO_HOME" "myproject" "$REPO_DIR")"
if [ "${#overrides[@]}" -eq 2 ] \
   && [[ "${overrides[0]}" == "$YOLO_HOME/compose.override.yml" ]] \
   && [[ "${overrides[1]}" == "$YOLO_HOME/myproject/compose.override.yml" ]]; then
    pass "Both overrides returned in correct order"
else
    fail "Both overrides returned in correct order — got: $(printf '%s, ' "${overrides[@]}")"
fi

# 5. Different project → only global (not the other project's override)
result=$(collect_user_overrides "$YOLO_HOME" "otherproject" "$REPO_DIR")
if [[ "$result" == "$YOLO_HOME/compose.override.yml" ]]; then
    pass "Other project only gets global override"
else
    fail "Other project only gets global override — got: $result"
fi

# 6. Repo-local override only
rm "$YOLO_HOME/compose.override.yml"
rm "$YOLO_HOME/myproject/compose.override.yml"
cat > "$REPO_DIR/compose.yolo.yml" << 'EOF'
services:
  claude:
    ports:
      - "5000:5000"
EOF
result=$(collect_user_overrides "$YOLO_HOME" "myproject" "$REPO_DIR")
if [[ "$result" == "$REPO_DIR/compose.yolo.yml" ]]; then
    pass "Repo-local override detected"
else
    fail "Repo-local override detected — got: $result"
fi

# 7. All three tiers → returned in order: repo-local, global, per-project
cat > "$YOLO_HOME/compose.override.yml" << 'EOF'
services:
  claude:
    ports:
      - "3000:3000"
EOF
mkdir -p "$YOLO_HOME/myproject"
cat > "$YOLO_HOME/myproject/compose.override.yml" << 'EOF'
services:
  claude:
    ports:
      - "8080:8080"
EOF
readarray -t overrides <<< "$(collect_user_overrides "$YOLO_HOME" "myproject" "$REPO_DIR")"
if [ "${#overrides[@]}" -eq 3 ] \
   && [[ "${overrides[0]}" == "$REPO_DIR/compose.yolo.yml" ]] \
   && [[ "${overrides[1]}" == "$YOLO_HOME/compose.override.yml" ]] \
   && [[ "${overrides[2]}" == "$YOLO_HOME/myproject/compose.override.yml" ]]; then
    pass "All three tiers returned in correct order"
else
    fail "All three tiers returned in correct order — got: $(printf '%s, ' "${overrides[@]}")"
fi

# 8. No project_dir arg → still works (backwards compat)
rm "$REPO_DIR/compose.yolo.yml"
result=$(collect_user_overrides "$YOLO_HOME" "myproject")
readarray -t overrides <<< "$result"
if [ "${#overrides[@]}" -eq 2 ] \
   && [[ "${overrides[0]}" == "$YOLO_HOME/compose.override.yml" ]] \
   && [[ "${overrides[1]}" == "$YOLO_HOME/myproject/compose.override.yml" ]]; then
    pass "Works without project_dir argument"
else
    fail "Works without project_dir argument — got: $(printf '%s, ' "${overrides[@]}")"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
