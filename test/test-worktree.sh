#!/usr/bin/env bash
# Test that hooks/worktree-create.sh emits the expected prefixed status lines
# on stderr for each scenario: new worktree, existing worktree, existing branch.
# Usage: ./test/test-worktree.sh
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

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hooks/worktree-create.sh"

# ─── Helper: set up a bare repo with an initial commit ──────────────────────

setup_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" commit --allow-empty -m "init" -q
}

# ─── Helper: run worktree-create.sh and capture stderr ──────────────────────

run_create() {
    local session="$1" repos="$2" base="$3"
    local stderr_file="$TMPDIR/stderr"
    YOLO_REPOS="$repos" YOLO_SESSION_BASE="$base" \
        "$SCRIPT" "$session" >/dev/null 2>"$stderr_file" || true
    cat "$stderr_file"
}

# ─── Test cases ─────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Worktree status output${RESET}"

# 1. New worktree → created:repo:branch
REPO1="$TMPDIR/repos/alpha"
setup_repo "$REPO1"

stderr=$(run_create "test-branch" "$REPO1" "$TMPDIR/sessions/s1")
if [[ "$stderr" == "created:alpha:test-branch" ]]; then
    pass "New worktree emits created:repo:branch"
else
    fail "New worktree emits created:repo:branch — got: $stderr"
fi

# 2. Existing worktree (run again) → exists:repo
stderr=$(run_create "test-branch" "$REPO1" "$TMPDIR/sessions/s1")
if [[ "$stderr" == "exists:alpha" ]]; then
    pass "Existing worktree emits exists:repo"
else
    fail "Existing worktree emits exists:repo — got: $stderr"
fi

# 3. Existing branch, no worktree → reused:repo:branch
REPO2="$TMPDIR/repos/beta"
setup_repo "$REPO2"
git -C "$REPO2" branch "reuse-me" 2>/dev/null

stderr=$(run_create "reuse-me" "$REPO2" "$TMPDIR/sessions/s2")
if [[ "$stderr" == "reused:beta:reuse-me" ]]; then
    pass "Existing branch emits reused:repo:branch"
else
    fail "Existing branch emits reused:repo:branch — got: $stderr"
fi

# 4. Multiple repos → one line per repo
REPO3="$TMPDIR/repos/gamma"
setup_repo "$REPO3"

stderr=$(run_create "multi-test" "$REPO2|$REPO3" "$TMPDIR/sessions/s3")
lines=$(echo "$stderr" | wc -l | tr -d ' ')
if [[ "$lines" -eq 2 ]]; then
    pass "Multiple repos emit one line per repo"
else
    fail "Multiple repos emit one line per repo — got $lines lines: $stderr"
fi

# 5. Stdout returns worktree path (single repo)
stdout=$(YOLO_REPOS="$REPO1" YOLO_SESSION_BASE="$TMPDIR/sessions/s1" \
    "$SCRIPT" "test-branch" 2>/dev/null)
if [[ "$stdout" == "$TMPDIR/sessions/s1/alpha" ]]; then
    pass "Single repo stdout is worktree path"
else
    fail "Single repo stdout is worktree path — got: $stdout"
fi

# 6. Stdout returns session base (multi-repo)
stdout=$(YOLO_REPOS="$REPO2|$REPO3" YOLO_SESSION_BASE="$TMPDIR/sessions/s3" \
    "$SCRIPT" "multi-test" 2>/dev/null)
if [[ "$stdout" == "$TMPDIR/sessions/s3" ]]; then
    pass "Multi-repo stdout is session base"
else
    fail "Multi-repo stdout is session base — got: $stdout"
fi

# 7. YOLO_WORKTREE_BASE → worktrees created at worktree base, not session base
REPO_WB="$TMPDIR/repos/delta"
setup_repo "$REPO_WB"

WB_SESSION_BASE="$TMPDIR/sessions/s-wb"
WB_WORKTREE_BASE="$TMPDIR/project/.yolo/worktrees/s-wb"

stdout=$(YOLO_REPOS="$REPO_WB" YOLO_SESSION_BASE="$WB_SESSION_BASE" YOLO_WORKTREE_BASE="$WB_WORKTREE_BASE" \
    "$SCRIPT" "wb-test" 2>/dev/null)
if [ -d "$WB_WORKTREE_BASE/delta" ] && [ -f "$WB_WORKTREE_BASE/delta/.git" ]; then
    pass "YOLO_WORKTREE_BASE: worktree created at worktree base"
else
    fail "YOLO_WORKTREE_BASE: worktree created at worktree base — dir missing"
fi
if [[ "$stdout" == "$WB_WORKTREE_BASE/delta" ]]; then
    pass "YOLO_WORKTREE_BASE: stdout returns worktree base path"
else
    fail "YOLO_WORKTREE_BASE: stdout returns worktree base path — got: $stdout"
fi

# 8. Without YOLO_WORKTREE_BASE → backward compat, uses YOLO_SESSION_BASE
REPO_COMPAT="$TMPDIR/repos/epsilon"
setup_repo "$REPO_COMPAT"

COMPAT_BASE="$TMPDIR/sessions/s-compat"
stdout=$(YOLO_REPOS="$REPO_COMPAT" YOLO_SESSION_BASE="$COMPAT_BASE" \
    "$SCRIPT" "compat-test" 2>/dev/null)
if [ -d "$COMPAT_BASE/epsilon" ] && [ -f "$COMPAT_BASE/epsilon/.git" ]; then
    pass "No YOLO_WORKTREE_BASE: falls back to YOLO_SESSION_BASE"
else
    fail "No YOLO_WORKTREE_BASE: falls back to YOLO_SESSION_BASE — dir missing"
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
