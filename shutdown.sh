#!/bin/bash
set -euo pipefail

# Shutdown confirmation script — runs inside a tmux display-popup.
# Shows git status summary, prompts for confirmation, then signals
# the host to tear down the container.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Find git repos (same logic as detect_git_repos in yolo)
repos=()
if [ -d "$WORKDIR/.git" ] || [ -f "$WORKDIR/.git" ]; then
    repos+=("$WORKDIR")
else
    for child in "$WORKDIR"/*/; do
        [ -d "$child" ] || continue
        if [ -d "$child/.git" ] || [ -f "$child/.git" ]; then
            repos+=("${child%/}")
        fi
    done
fi

has_changes=false

for repo in "${repos[@]}"; do
    name=$(basename "$repo")
    uncommitted=$(git -C "$repo" status --porcelain 2>/dev/null) || true
    unpushed=$(git -C "$repo" log @{u}..HEAD --oneline 2>/dev/null) || true

    if [ -n "$uncommitted" ] || [ -n "$unpushed" ]; then
        has_changes=true
        echo -e "${BOLD}${name}${RESET}"
        if [ -n "$uncommitted" ]; then
            count=$(echo "$uncommitted" | wc -l | tr -d ' ')
            echo -e "  ${YELLOW}${count} uncommitted change(s)${RESET}"
        fi
        if [ -n "$unpushed" ]; then
            count=$(echo "$unpushed" | wc -l | tr -d ' ')
            echo -e "  ${RED}${count} unpushed commit(s)${RESET}"
        fi
    fi
done

if [ "$has_changes" = "true" ]; then
    echo ""
    echo -e "${YELLOW}Warning: You have unsaved work.${RESET}"
else
    echo -e "${GREEN}All changes committed and pushed.${RESET}"
fi

echo ""
echo -ne "Shut down this session? [y/${BOLD}N${RESET}] "
read -r choice

case "${choice:-n}" in
    y|Y)
        # Kill tmux session — host-side yolo detects this and handles
        # container removal and cleanup.
        tmux kill-session
        ;;
    *)
        # Popup closes, user stays in tmux
        ;;
esac
