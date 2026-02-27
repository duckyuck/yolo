#!/bin/bash
set -euo pipefail

# Creates git worktrees for all configured repos in a YOLO session.
# Called by entrypoint.sh at container startup.
#
# Usage: worktree-create.sh <session-name>
# Env:   YOLO_REPOS (pipe-delimited repo paths), YOLO_SESSION_BASE
# Stdout: worktree path (single repo) or session base (multi-repo)
# Stderr: diagnostic messages

NAME="${1:-${SESSION_NAME:-}}"

if [ -z "$NAME" ]; then
    echo "Usage: worktree-create.sh <session-name>" >&2
    exit 1
fi

if [ -z "${YOLO_REPOS:-}" ]; then
    echo "Error: YOLO_REPOS not set" >&2
    exit 1
fi

if [ -z "${YOLO_SESSION_BASE:-}" ]; then
    echo "Error: YOLO_SESSION_BASE not set" >&2
    exit 1
fi

mkdir -p "$YOLO_SESSION_BASE"

IFS='|' read -ra REPOS <<< "$YOLO_REPOS"

for repo_path in "${REPOS[@]}"; do
    repo_name=$(basename "$repo_path")
    wt_path="$YOLO_SESSION_BASE/$repo_name"

    # Idempotent: skip if worktree already exists
    if [ -d "$wt_path" ] && { [ -d "$wt_path/.git" ] || [ -f "$wt_path/.git" ]; }; then
        echo "exists:$repo_name" >&2
        continue
    fi

    # Fetch latest from remote
    current_branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch="main"
    git -C "$repo_path" fetch origin "$current_branch" 2>/dev/null || true

    # Determine start point: prefer remote-tracking branch
    start_point="origin/$current_branch"
    if ! git -C "$repo_path" rev-parse --verify "$start_point" >/dev/null 2>&1; then
        start_point="$current_branch"
    fi

    # Create worktree
    if git -C "$repo_path" rev-parse --verify "$NAME" >/dev/null 2>&1; then
        git -C "$repo_path" worktree add "$wt_path" "$NAME" >/dev/null 2>&1
        echo "reused:$repo_name:$NAME" >&2
    else
        git -C "$repo_path" worktree add -b "$NAME" "$wt_path" "$start_point" >/dev/null 2>&1
        echo "created:$repo_name:$NAME" >&2
    fi
done

# Return path: single repo = worktree path, multi-repo = session base
if [ ${#REPOS[@]} -eq 1 ]; then
    echo "$YOLO_SESSION_BASE/$(basename "${REPOS[0]}")"
else
    echo "$YOLO_SESSION_BASE"
fi
