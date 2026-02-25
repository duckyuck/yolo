#!/bin/bash
set -euo pipefail

cd "${WORKDIR}"

# --- SSH setup ---
# Load SSH keys into an agent so git can authenticate, then delete the key files.
# This prevents Claude from reading private key material while still allowing git operations.
if [ -d /mnt/host-ssh ]; then
    mkdir -p /home/claude/.ssh
    chmod 700 /home/claude/.ssh

    # Copy known_hosts and public keys (safe to keep on disk)
    for f in /mnt/host-ssh/*; do
        [ -f "$f" ] || continue
        fname="$(basename "$f")"
        [ "$fname" = "config" ] && continue
        cp "$f" "/home/claude/.ssh/$fname"
    done
    chmod 644 /home/claude/.ssh/*.pub 2>/dev/null || true
    chmod 644 /home/claude/.ssh/known_hosts 2>/dev/null || true

    # Filter out macOS-only options from SSH config
    if [ -f /mnt/host-ssh/config ]; then
        sed -e '/UseKeychain/d' \
            -e '/IdentityAgent.*1password/d' \
            -e '/IdentityAgent.*Group Containers/d' \
            /mnt/host-ssh/config > /home/claude/.ssh/config
        chmod 600 /home/claude/.ssh/config
    fi

    # Start ssh-agent at a fixed socket path so all processes can find it
    SSH_SOCK="/home/claude/.ssh/agent.sock"
    rm -f "$SSH_SOCK"
    eval "$(ssh-agent -a "$SSH_SOCK" -s)" > /dev/null
    export SSH_AUTH_SOCK="$SSH_SOCK"
    export SSH_AGENT_PID

    # Load private keys into agent (skip passphrase-protected keys)
    for key in /home/claude/.ssh/id_*; do
        [ -f "$key" ] || continue
        [[ "$key" == *.pub ]] && continue
        chmod 600 "$key"
        # Test if key is unencrypted (ssh-keygen -y -P "" fails on encrypted keys)
        if ssh-keygen -y -P "" -f "$key" >/dev/null 2>&1; then
            ssh-add "$key" 2>/dev/null || true
        fi
    done

    # Delete private key files — agent holds them in memory
    for key in /home/claude/.ssh/id_*; do
        [ -f "$key" ] || continue
        [[ "$key" == *.pub ]] && continue
        rm -f "$key"
    done

    # Write env vars so docker exec / interactive shells pick up the agent
    cat > /home/claude/.ssh/agent.env <<AGENTEOF
export SSH_AUTH_SOCK="$SSH_SOCK"
export SSH_AGENT_PID="$SSH_AGENT_PID"
AGENTEOF

    # Source agent env in all new bash sessions (login and non-login)
    AGENT_SOURCE='[ -f ~/.ssh/agent.env ] && source ~/.ssh/agent.env'
    if ! grep -q 'agent.env' /home/claude/.bashrc 2>/dev/null; then
        echo "$AGENT_SOURCE" >> /home/claude/.bashrc
    fi
    if ! grep -q 'agent.env' /home/claude/.profile 2>/dev/null; then
        echo "$AGENT_SOURCE" >> /home/claude/.profile
    fi
fi

# --- Claude config directory ---
# Copy host Claude config directory into container (host mount is read-only)
# Excludes projects/ (persisted via bind mount) and .credentials.json (shared bind mount)
if [ -d /mnt/host-claude ]; then
    mkdir -p /home/claude/.claude
    tar -C /mnt/host-claude --exclude='./projects' --exclude='./.credentials.json' -cf - . \
        | tar -C /home/claude/.claude -xf - 2>/dev/null || true
    # Transform host paths to container paths in the local copy
    if [ -n "${HOST_HOME:-}" ]; then
        find /home/claude/.claude -name '*.json' ! -name '.credentials.json' -type f -exec \
            sed -i "s|${HOST_HOME}|/home/claude|g" {} +
    fi
fi

# --- .claude.json ---
# Copy host .claude.json (OAuth account info needed for auth)
# Transform paths in values but restore project keys to host paths
# (container mounts directories at host paths, so Claude looks up trust by host path)
if [ -f /mnt/host-claude.json ]; then
    if [ -n "${HOST_HOME:-}" ]; then
        sed "s|${HOST_HOME}|/home/claude|g" /mnt/host-claude.json \
            | jq --arg from "/home/claude" --arg to "${HOST_HOME}" \
                '.installMethod = "native"
                | .skipDangerousModePermissionPrompt = true
                | .projects = (.projects // {} | to_entries | map(.key = (.key | gsub($from; $to))) | from_entries)' \
            > /home/claude/.claude.json
    else
        jq '.installMethod = "native" | .skipDangerousModePermissionPrompt = true' \
            /mnt/host-claude.json > /home/claude/.claude.json
    fi
fi

# --- Trust dialogs ---
# Claude Code stores workspace trust in ~/.claude.json under projects["/absolute/path"]
accept_trust() {
    local dir="$1"
    local claude_json="/home/claude/.claude.json"
    if [ -f "$claude_json" ]; then
        jq --arg dir "$dir" '.projects[$dir].hasTrustDialogAccepted = true' \
            "$claude_json" > "$claude_json.tmp" \
            && mv "$claude_json.tmp" "$claude_json"
    fi
}

accept_trust "${WORKDIR}"

# Also accept trust for each worktree directory in multi-repo mode
for wt_dir in "${WORKDIR}"/*/; do
    [ -d "$wt_dir" ] || continue
    wt_dir="${wt_dir%/}"
    if [ -d "$wt_dir/.git" ] || [ -f "$wt_dir/.git" ]; then
        accept_trust "$wt_dir"
    fi
done

# --- Tmux session ---
SESSION="${SESSION_NAME}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"

# Kill any stale session from a previous run
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Pass SSH_AUTH_SOCK into tmux so git works inside all windows
tmux set-environment -g SSH_AUTH_SOCK "${SSH_AUTH_SOCK:-}" 2>/dev/null || true
tmux set-environment -g SSH_AGENT_PID "${SSH_AGENT_PID:-}" 2>/dev/null || true

tmux new-session -d -s "$SESSION" -n claude -c "${WORKDIR}"
CLAUDE_CMD="claude --dangerously-skip-permissions --model ${CLAUDE_MODEL}"
if [ "${CLAUDE_CONTINUE:-}" = "true" ]; then
    # Only --continue if conversation history exists; otherwise start fresh
    if find /home/claude/.claude/projects -mindepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
        CLAUDE_CMD="${CLAUDE_CMD} --continue"
    fi
fi
tmux send-keys -t "${SESSION}:claude" "$CLAUDE_CMD" Enter

# --- Signal handling ---
cleanup() {
    echo "Shutting down..."
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    # Kill ssh-agent
    if [ -n "${SSH_AGENT_PID:-}" ]; then
        kill "$SSH_AGENT_PID" 2>/dev/null || true
    fi
    pkill -P $$ || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Wait for signals (sleep wakes up immediately on SIGTERM)
while true; do
    sleep 1 &
    wait $!
done
