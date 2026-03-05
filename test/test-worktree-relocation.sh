#!/usr/bin/env bash
# Test worktree relocation: worktrees created at project-local path,
# symlinks at ~/.yolo for backward compat.
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

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CREATE_SCRIPT="$SCRIPT_DIR/hooks/worktree-create.sh"

setup_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" commit --allow-empty -m "init" -q
}

echo -e "\n${BOLD}Worktree relocation${RESET}"

# Setup: project dir with one repo
PROJECT_DIR="$TMPDIR/workspace/myproject"
REPO="$PROJECT_DIR/backend"
setup_repo "$REPO"

YOLO_DIR="$TMPDIR/yolo-home/myproject"
SESSION_BASE="$YOLO_DIR/feat-x"
WORKTREE_BASE="$PROJECT_DIR/.yolo/worktrees/feat-x"
mkdir -p "$SESSION_BASE"

# 1. worktree-create.sh creates at YOLO_WORKTREE_BASE
YOLO_REPOS="$REPO" YOLO_SESSION_BASE="$SESSION_BASE" YOLO_WORKTREE_BASE="$WORKTREE_BASE" \
    "$CREATE_SCRIPT" "feat-x" >/dev/null 2>&1

if [ -d "$WORKTREE_BASE/backend" ]; then
    pass "Worktree created at project-local path"
else
    fail "Worktree created at project-local path"
fi

if [ ! -d "$SESSION_BASE/backend" ]; then
    pass "No worktree at old ~/.yolo path"
else
    fail "No worktree at old ~/.yolo path — dir exists there too"
fi

# 2. Symlink from old path to new path
ln -s "$WORKTREE_BASE/backend" "$SESSION_BASE/backend"
if [ -L "$SESSION_BASE/backend" ] && [ -d "$SESSION_BASE/backend" ]; then
    pass "Symlink at old path resolves to real worktree"
else
    fail "Symlink at old path resolves to real worktree"
fi

# 3. git operations work through symlink
BRANCH=$(git -C "$SESSION_BASE/backend" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ "$BRANCH" == "feat-x" ]]; then
    pass "Git operations work through symlink"
else
    fail "Git operations work through symlink — got branch: $BRANCH"
fi

# 4. Migration: move real dir → symlink
MIGRATE_PROJECT="$TMPDIR/workspace/migrateproject"
MIGRATE_REPO="$MIGRATE_PROJECT/api"
setup_repo "$MIGRATE_REPO"

MIGRATE_YOLO="$TMPDIR/yolo-home/migrateproject"
MIGRATE_OLD="$MIGRATE_YOLO/old-session"
MIGRATE_NEW="$MIGRATE_PROJECT/.yolo/worktrees/old-session"

# Create worktree at old location (simulating pre-migration state)
YOLO_REPOS="$MIGRATE_REPO" YOLO_SESSION_BASE="$MIGRATE_OLD" \
    "$CREATE_SCRIPT" "old-session" >/dev/null 2>&1

if [ -d "$MIGRATE_OLD/api" ] && [ ! -L "$MIGRATE_OLD/api" ]; then
    pass "Pre-migration: real worktree at old path"
else
    fail "Pre-migration: real worktree at old path"
fi

# Simulate migration: mv to new location, replace with symlink
mkdir -p "$MIGRATE_NEW"
mv "$MIGRATE_OLD/api" "$MIGRATE_NEW/api"
ln -s "$MIGRATE_NEW/api" "$MIGRATE_OLD/api"

if [ -L "$MIGRATE_OLD/api" ] && [ -d "$MIGRATE_NEW/api" ]; then
    pass "Migration: moved to new path + symlinked"
else
    fail "Migration: moved to new path + symlinked"
fi

BRANCH=$(git -C "$MIGRATE_OLD/api" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ "$BRANCH" == "old-session" ]]; then
    pass "Migration: git still works through symlink"
else
    fail "Migration: git still works through symlink — got: $BRANCH"
fi

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed${RESET}"
    exit 1
fi
