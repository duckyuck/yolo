#!/bin/bash
set -euo pipefail

cd "${WORKDIR}"

# --- Docker socket permissions ---
# When the host's Docker socket is mounted (for nested yolo / Docker outside of Docker),
# it typically appears as root:root srw-rw---- inside the container. Add the claude user
# to a group matching the socket's GID so docker commands work without sudo.
if [ -S /var/run/docker.sock ] && ! docker info >/dev/null 2>&1; then
    DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
    [[ "$DOCKER_SOCK_GID" =~ ^[0-9]+$ ]] || DOCKER_SOCK_GID=0
    if [ "$DOCKER_SOCK_GID" -eq 0 ]; then
        # Socket owned by root:root — no group trick will help, widen permissions
        sudo chmod 666 /var/run/docker.sock
    else
        # Find or create a group matching the socket's GID, add claude to it
        DOCKER_GROUP=$(getent group "$DOCKER_SOCK_GID" 2>/dev/null | cut -d: -f1) || true
        if [ -z "$DOCKER_GROUP" ]; then
            DOCKER_GROUP="docker-host"
            sudo groupadd -g "$DOCKER_SOCK_GID" "$DOCKER_GROUP"
        fi
        sudo usermod -aG "$DOCKER_GROUP" claude
        # newgrp activates the group for the rest of this process
        exec sg "$DOCKER_GROUP" -c "$(printf '%q ' "$0" "$@")"
    fi
fi

# --- SSH setup ---
# Authenticate git via SSH agent. Prefers the host agent forwarded by Docker
# Desktop (works with 1Password, Keychain, etc.). Falls back to a local
# ssh-agent for unencrypted keys. Private key files are always deleted.
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
        sed -e '/^[[:space:]]*UseKeychain/d' \
            -e '/^[[:space:]]*IdentityAgent.*1password/d' \
            -e '/^[[:space:]]*IdentityAgent.*Group Containers/d' \
            /mnt/host-ssh/config > /home/claude/.ssh/config
        chmod 600 /home/claude/.ssh/config
    fi

    # Choose SSH agent: prefer forwarded host agent, fall back to local
    FORWARDED_AGENT="/run/host-services/ssh-auth.sock"
    # Docker Desktop's forwarded socket is typically root:root 660 — make it accessible
    if [ -S "$FORWARDED_AGENT" ] && ! SSH_AUTH_SOCK="$FORWARDED_AGENT" ssh-add -l >/dev/null 2>&1; then
        sudo chmod 666 "$FORWARDED_AGENT" 2>/dev/null || true
    fi
    if [ -S "$FORWARDED_AGENT" ] && SSH_AUTH_SOCK="$FORWARDED_AGENT" ssh-add -l >/dev/null 2>&1; then
        # Host SSH agent forwarded via Docker Desktop — use it directly
        export SSH_AUTH_SOCK="$FORWARDED_AGENT"
    else
        # Start local ssh-agent at a fixed socket path
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
            if ssh-keygen -y -P "" -f "$key" >/dev/null 2>&1; then
                ssh-add "$key" 2>/dev/null || true
            fi
        done
    fi

    # Delete private key files — agent holds them in memory (or host agent is forwarded)
    for key in /home/claude/.ssh/id_*; do
        [ -f "$key" ] || continue
        [[ "$key" == *.pub ]] && continue
        rm -f "$key"
    done

    # Write env vars so docker exec / interactive shells pick up the agent
    cat > /home/claude/.ssh/agent.env <<AGENTEOF
export SSH_AUTH_SOCK="$SSH_AUTH_SOCK"
AGENTEOF
    [ -n "${SSH_AGENT_PID:-}" ] && echo "export SSH_AGENT_PID=\"$SSH_AGENT_PID\"" >> /home/claude/.ssh/agent.env

    # Source agent env in all new bash sessions (login and non-login)
    AGENT_SOURCE='[ -f ~/.ssh/agent.env ] && source ~/.ssh/agent.env'
    if ! grep -q 'agent.env' /home/claude/.bashrc 2>/dev/null; then
        echo "$AGENT_SOURCE" >> /home/claude/.bashrc
    fi
    if ! grep -q 'agent.env' /home/claude/.profile 2>/dev/null; then
        echo "$AGENT_SOURCE" >> /home/claude/.profile
    fi
fi

# --- Git config ---
# Copy host gitconfig and filter out macOS-specific settings (same pattern as SSH config above).
# The host file is mounted read-only at /mnt/host-gitconfig; we create a writable copy.
if [ -f /mnt/host-gitconfig ]; then
    sed -e '/^[[:space:]]*helper[[:space:]]*=[[:space:]]*osxkeychain/d' \
        -e '/^[[:space:]]*helper[[:space:]]*=[[:space:]]*\/usr\/lib\/git-core\/git-credential-osxkeychain/d' \
        /mnt/host-gitconfig > /home/claude/.gitconfig
fi

# If GH_TOKEN is available, configure gh as the git credential helper for HTTPS
if [ -n "${GH_TOKEN:-}" ]; then
    gh auth setup-git 2>/dev/null || true
fi

# --- Claude config directory ---
# Copy host Claude config directory into container (host mount is read-only)
# Excludes projects/ (persisted via bind mount) and .credentials.json (shared bind mount)
if [ -d /mnt/host-claude ]; then
    mkdir -p /home/claude/.claude
    tar -C /mnt/host-claude --exclude='./projects' --exclude='./.credentials.json' --exclude='./CLAUDE.md' -cf - . \
        | tar -C /home/claude/.claude -xf - 2>/dev/null || true
    # Transform host paths to container paths in the local copy
    if [ -n "${HOST_HOME:-}" ]; then
        escaped_host_home=$(printf '%s\n' "$HOST_HOME" | sed 's/[|&/\]/\\&/g')
        find /home/claude/.claude -name '*.json' ! -name '.credentials.json' -type f -exec \
            sed -i "s|${escaped_host_home}|/home/claude|g" {} +
    fi
fi

# --- .claude.json ---
# Copy host .claude.json (OAuth account info needed for auth)
# Transform paths in values but restore project keys to host paths
# (container mounts directories at host paths, so Claude looks up trust by host path)
if [ -f /mnt/host-claude.json ]; then
    if [ -n "${HOST_HOME:-}" ]; then
        escaped_host_home=$(printf '%s\n' "$HOST_HOME" | sed 's/[|&/\]/\\&/g')
        if ! sed "s|${escaped_host_home}|/home/claude|g" /mnt/host-claude.json \
            | jq --arg from "/home/claude" --arg to "${HOST_HOME}" \
                '.installMethod = "native"
                | .skipDangerousModePermissionPrompt = true
                | .projects = (.projects // {} | to_entries | map(.key = (.key | gsub($from; $to))) | from_entries)' \
            > /home/claude/.claude.json; then
            echo "Warning: failed to transform .claude.json, copying as-is" >&2
            cp /mnt/host-claude.json /home/claude/.claude.json
        fi
    else
        if ! jq '.installMethod = "native" | .skipDangerousModePermissionPrompt = true' \
            /mnt/host-claude.json > /home/claude/.claude.json; then
            echo "Warning: failed to transform .claude.json, copying as-is" >&2
            cp /mnt/host-claude.json /home/claude/.claude.json
        fi
    fi
fi

# --- Docker environment rules ---
# Write Docker context as a Claude Code rules file (separate from user's CLAUDE.md,
# which is bind-mounted read-write from the host).
mkdir -p /home/claude/.claude/rules
cat > /home/claude/.claude/rules/yolo-docker.md << 'CONTAINEREOF'
# Environment: Docker container (yolo)

- Ports you bind are NOT accessible on the host. Bind to 0.0.0.0 and tell the user to add port forwarding in ~/.yolo/compose.override.yml or use network_mode: host.
CONTAINEREOF

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

# --- Shell environment ---
# Export WORKDIR and snap every new shell to it. Claude Code's Bash tool spawns
# a new shell per command and may reset CWD to the wrong directory (e.g. the
# main repo instead of the session worktree). This guarantees correct CWD.
WORKDIR_EXPORT="export WORKDIR=\"${WORKDIR}\""
WORKDIR_CD='[ -n "$WORKDIR" ] && cd "$WORKDIR"'
for rcfile in /home/claude/.bashrc /home/claude/.profile; do
    if ! grep -q 'cd "$WORKDIR"' "$rcfile" 2>/dev/null; then
        echo "$WORKDIR_EXPORT" >> "$rcfile"
        echo "$WORKDIR_CD" >> "$rcfile"
    fi
done

# --- Tmux session ---
SESSION="${SESSION_NAME}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"

# Kill any stale session from a previous run
tmux kill-session -t "$SESSION" 2>/dev/null || true

tmux new-session -d -s "$SESSION" -n claude -c "${WORKDIR}"

# Pass SSH_AUTH_SOCK into tmux so git works inside new windows/panes
# (must be after new-session to ensure tmux server is running)
tmux set-environment -g SSH_AUTH_SOCK "${SSH_AUTH_SOCK:-}" 2>/dev/null || true
tmux set-environment -g SSH_AGENT_PID "${SSH_AGENT_PID:-}" 2>/dev/null || true
CLAUDE_CMD="claude --dangerously-skip-permissions --model ${CLAUDE_MODEL}"
# Auto-continue if conversation history exists from a previous run
if find /home/claude/.claude/projects -mindepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
    CLAUDE_CMD="${CLAUDE_CMD} --continue"
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

# Wait for signals or shutdown sentinel
while true; do
    sleep 1 &
    wait $!
    # Check if shutdown was requested via Ctrl-B Shift-Q
    if [ -f /tmp/.yolo-shutdown ]; then
        cleanup
    fi
done
