#!/usr/bin/env bash
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

# Extract update_sessions_json from yolo script
eval "$(sed -n '/^update_sessions_json()/,/^}/p' "$(dirname "$0")/../yolo")"

echo -e "\n${BOLD}sessions.json project_dir${RESET}"

# 1. project_dir is stored in sessions.json
YOLO_DIR="$TMPDIR/yolo-home/myproject"
mkdir -p "$YOLO_DIR"
PROJECT_DIR="/Users/test/workspace/myproject"

update_sessions_json "$YOLO_DIR" "feat-x" "$PROJECT_DIR" "/Users/test/workspace/myproject/backend"

STORED=$(jq -r '.["feat-x"].project_dir' "$YOLO_DIR/sessions.json")
if [[ "$STORED" == "$PROJECT_DIR" ]]; then
    pass "project_dir stored in sessions.json"
else
    fail "project_dir stored in sessions.json — got: $STORED"
fi

# 2. Repo source is still stored
REPO_SRC=$(jq -r '.["feat-x"].backend.source' "$YOLO_DIR/sessions.json")
if [[ "$REPO_SRC" == "/Users/test/workspace/myproject/backend" ]]; then
    pass "repo source still stored"
else
    fail "repo source still stored — got: $REPO_SRC"
fi

# 3. Second session doesn't clobber first
update_sessions_json "$YOLO_DIR" "feat-y" "$PROJECT_DIR" "/Users/test/workspace/myproject/frontend"
STILL_THERE=$(jq -r '.["feat-x"].project_dir' "$YOLO_DIR/sessions.json")
if [[ "$STILL_THERE" == "$PROJECT_DIR" ]]; then
    pass "second session doesn't clobber first"
else
    fail "second session doesn't clobber first — got: $STILL_THERE"
fi

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
