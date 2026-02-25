# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`yolo` is a Docker-based runner for Claude Code that provides isolated development sessions with automatic git worktree management. It runs Claude Code inside containers with per-session branch isolation, secure SSH forwarding, and host config synchronization.

## Commands

```bash
# Start or reattach to a session (idempotent, auto-rebuilds if config changed)
./yolo up <session-name>

# Stop container, prompt for worktree cleanup
./yolo down <session-name>

# Copy files into a running session's workdir
./yolo cp <session-name> <file...>

# Print worktree base path for a session
./yolo path <session-name>
./yolo path <project>/<session-name>

# Show status of one or all sessions in current project
./yolo status [session-name]

# Show all sessions across all projects
./yolo ps

# Self-update or print version
./yolo update
./yolo version

# Verbose mode (shows Docker build logs)
./yolo up <name> --verbose
```

There are no tests, linters, or build steps — the project is a set of shell scripts and Docker configuration.

## Architecture

The project has seven files that form a pipeline:

1. **`yolo`** — Host-side CLI orchestrator (bash). Handles session lifecycle, credential extraction, worktree creation, compose override generation, and container attachment. All user interaction happens here.

2. **`docker-compose.yml`** — Service definition. Defines base volume mounts (gitconfig, SSH keys, Claude config) and environment variables. The `yolo` script generates a `docker-compose.override.yml` per session with additional mounts.

3. **`Dockerfile`** — Ubuntu 24.04 image with git, tmux, jq, gh, and Claude Code installed via `curl https://claude.ai/install.sh`. Creates a `claude` user matching the host UID/GID.

4. **`entrypoint.sh`** — Container startup. Runs three setup phases:
   - SSH: copies keys, filters macOS-specific config, loads keys into ssh-agent, then deletes private key files from disk
   - Config: copies `~/.claude` and `~/.claude.json` with host->container path transforms, accepts workspace trust
   - Tmux: starts a tmux session running `claude --dangerously-skip-permissions` (with `--continue` if conversation history exists)

5. **`hooks/worktree-create.sh`** — Worktree creation script. Called by `yolo up` on the host before the container starts. Fetches latest code and creates git worktrees for all configured repos at the session base directory. Idempotent (reuses existing worktrees).

6. **`hooks/worktree-remove.sh`** — Worktree removal utility. Can be called manually inside the container. Auto-removes worktrees that are clean and not ahead of remote. Host-side cleanup is handled by `yolo down`.

7. **`tmux.conf`** — Configures true color, mouse support, and `Ctrl-B Shift-N` to open new Claude windows.

## Key Design Patterns

**Session naming flows through everything.** The `<session-name>` argument becomes: the git branch name, the worktree directory name, the Docker Compose project prefix (`yolo-{project}-{safe-name}`), and the tmux session name.

**Worktree creation happens on the host** before the container starts. `yolo up` calls `hooks/worktree-create.sh` which creates worktrees in `~/.yolo/{project}/{session}/`. The session base directory and parent `.git` directories are mounted into the container as Docker volumes.

**Config sync is one-directional** (host -> container). The host's `~/.claude` and `~/.claude.json` are mounted read-only, then copied and path-transformed (`$HOME` -> `/home/claude`) inside the container. On `up`, config is re-synced via `docker cp`.

**`up` auto-detects changes** to compose files and build context (Dockerfile, entrypoint.sh, tmux.conf) via a content hash. If anything changed, it rebuilds the image and recreates the container with `--continue` to resume the Claude session.

**Auto-recovery:** if the tmux session dies inside a running container (e.g. Ctrl-C instead of Ctrl-B d), `up` automatically creates a new tmux session and reattaches.

**Extra mounts** can be added in `~/.yolo/mounts` (one host path per line, mounted read-only).

**Auth priority:** `ANTHROPIC_API_KEY` env var -> `CLAUDE_CODE_OAUTH_TOKEN` env var -> `~/.claude/.credentials.json` OAuth token.

## README Style

The README has a casual, opinionated tone (e.g. "Stop clicking yes every 30 seconds. Let Claude Code off the leash."). When updating the README for feature changes, only change the parts that are factually wrong or outdated — do not rewrite the whole file or flatten the tone into dry technical docs. Preserve the personality, humor, and existing structure.

## Bash Requirements

- Requires bash 4+ (uses `readarray`, associative features)
- Uses `set -euo pipefail` throughout
- TTY detection (`[ -t 1 ]`) controls whether spinners/colors are shown
