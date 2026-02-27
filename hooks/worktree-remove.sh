#!/bin/bash
set -euo pipefail

# Removes YOLO session worktrees that are clean and not ahead of remote.
# Utility script — can be called manually inside the container.
# Host-side cleanup is handled by `yolo down`.
#
# Env: YOLO_REPOS (pipe-delimited repo paths), YOLO_SESSION_BASE

if [ -z "${YOLO_REPOS:-}" ] || [ -z "${YOLO_SESSION_BASE:-}" ]; then
    exit 0
fi

IFS='|' read -ra REPOS <<< "$YOLO_REPOS"

for repo_path in "${REPOS[@]}"; do
    repo_name=$(basename "$repo_path")
    wt_path="$YOLO_SESSION_BASE/$repo_name"

    [ -d "$wt_path" ] || continue

    # Keep if dirty
    if [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
        echo "Keeping $repo_name worktree (uncommitted changes)" >&2
        continue
    fi

    # Keep if ahead of remote
    current_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch="main"
    ahead=0
    if git -C "$wt_path" rev-parse --verify "origin/$current_branch" >/dev/null 2>&1; then
        ahead=$(git -C "$wt_path" rev-list --count "origin/$current_branch..HEAD" 2>/dev/null) || ahead=0
    fi

    if [ "$ahead" -gt 0 ]; then
        echo "Keeping $repo_name worktree ($ahead commits ahead)" >&2
        continue
    fi

    # Safe to remove
    git -C "$repo_path" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
    echo "Removed $repo_name worktree" >&2
done

# Clean up empty session directory
rmdir "$YOLO_SESSION_BASE" 2>/dev/null || true
