# yolo

**Stop clicking "yes" every 30 seconds. Let Claude Code off the leash.**

Claude Code is great, but babysitting it through permission prompts gets old fast. yolo throws Claude into a Docker container with `--dangerously-skip-permissions` so it can actually get work done while you go do something else — like grab coffee, review a PR, or spin up *another* Claude on a different task.

Each session gets its own container with your project directory mounted directly — no git required, no ceremony. Run as many sessions as you want in parallel. They can't mess up your host, and you don't have to sit there approving every `mkdir`.

Need branch isolation? Add `--worktree` and each session gets its own git worktree on a dedicated branch. Got a project with multiple repos? yolo picks them all up and creates a worktree for each one.

```
+----------------------------------------------------------+
|  your-project/                                           |
|                                                          |
|  yolo up            yolo up second      (bind mode)      |
|       |                   |                              |
|       v                   v                              |
|  +--------------+   +--------------+                     |
|  | Container    |   | Container    |   same project dir  |
|  | "default"    |   | "second"     |   mounted into both |
|  |              |   |              |                     |
|  | Claude Code  |   | Claude Code  |                     |
|  | in tmux      |   | in tmux      |                     |
|  +--------------+   +--------------+                     |
|                                                          |
|  yolo up feat/auth --worktree         (worktree mode)    |
|       |                                                  |
|       v                                                  |
|  +--------------+                                        |
|  | Container    |   isolated worktree                    |
|  | branch:      |   on its own branch                    |
|  | feat/auth    |                                        |
|  |              |                                        |
|  | Claude Code  |                                        |
|  | in tmux      |                                        |
|  +--------------+                                        |
+----------------------------------------------------------+
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/sourcemagnet/yolo/main/install.sh | bash
```

### Requirements

- bash 4+ (macOS ships with 3.x — `brew install bash`)
- [Docker](https://docs.docker.com/get-docker/)
- macOS or Linux
- git (only needed for `--worktree` mode)

## Quick Start

```bash
cd your-project
yolo up                     # mounts your project, drops you into Claude
```

That's it. Claude is now working unsupervised in a container. Go do something else. When you're done:

```bash
# Detach first (keeps container running):
#   Ctrl-B d

yolo down                   # stops the container
```

Want branch isolation? Use worktree mode:

```bash
yolo up feat/auth --worktree   # creates branch, worktree, container
yolo down feat/auth            # stops container, offers to clean up worktrees
```

## What Happens When You Run `yolo up`

A lot, actually — but you don't have to think about any of it:

1. Mounts your project directory into a Docker container (or creates worktrees if you passed `--worktree`)
2. Builds a container with Claude Code, git, tmux, and GitHub CLI
3. Forwards your SSH keys, git config, and Claude config
4. Starts Claude Code inside tmux with `--dangerously-skip-permissions`
5. Attaches your terminal to the tmux session

Everything is idempotent — running `yolo up` again on the same session just reattaches you. Mash the command as many times as you want.

## Commands

### `yolo up [name]`

Start a new session or reattach to an existing one.

```bash
yolo up                         # bind mode, "default" session
yolo up my-task                 # bind mode, named session
yolo up feat/add-auth --worktree   # worktree mode, branch isolation
```

Without a name, the session is called "default". In bind mode, your project directory is mounted directly. With `--worktree`, the session name becomes the git branch name and the worktree directory.

### `yolo down [name]`

Stop the container and clean up.

```bash
yolo down                 # stop the "default" session
yolo down feat/add-auth   # stop a named session
```

This will:
- Stop and remove the Docker container
- For worktree sessions: check each worktree for uncommitted changes or unpushed commits, auto-remove clean worktrees, or prompt you for ones with changes
- Optionally delete the branch too (answer `b` at the prompt)

### `yolo cp <name> <file...>`

Copy files into a running session's working directory.

```bash
yolo cp feat/add-auth spec.md notes.txt
```

Handy for dropping in specs, context files, or anything else Claude should see.

### `yolo path <name>`

Print the worktree base path for a session (worktree mode only).

```bash
yolo path feat/add-auth
yolo path my-project/feat/add-auth   # cross-project
```

### `yolo status [name]`

Show the state of sessions.

```bash
yolo status                 # all sessions in the current project
yolo status feat/add-auth   # one specific session
```

Output includes container status (running/stopped). For worktree sessions, also shows per-worktree info — how many commits ahead you are, whether there are uncommitted changes, and if the branch has already been merged.

### `yolo ps`

List all sessions across all projects.

```bash
yolo ps
```

```
my-project
  feat-add-auth: running
  fix-header-bug: stopped
another-project
  refactor-cleanup: running
```

### `yolo update`

Update to the latest release.

```bash
yolo update
```

### `yolo version`

Print the installed version.

## Options

| Option | Description |
|---|---|
| `--worktree` | Use git worktree isolation (creates a branch per session) |
| `--port <port>` | Expose a container port to the host (repeatable) |
| `--verbose`, `-v` | Show Docker build logs and detailed output |
| `--version` | Print version |
| `-h`, `--help` | Show help |

## Authentication

yolo resolves credentials in this order:

| Priority | Method | How |
|---|---|---|
| 1 | `ANTHROPIC_API_KEY` | Environment variable — works with any API key |
| 2 | `CLAUDE_CODE_OAUTH_TOKEN` | Environment variable — OAuth token |
| 3 | `~/.claude/.credentials.json` | OAuth token from Claude Code login (mounted read-write) |

If you've logged into Claude Code at least once, authentication is automatic — yolo mounts your credentials file into the container. Otherwise, set one of the environment variables:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
yolo up my-session
```

## Tmux — Working Inside a Session

Each session runs inside [tmux](https://github.com/tmux/tmux). Here are the key shortcuts:

| Shortcut | Action |
|---|---|
| `Ctrl-B d` | **Detach** — exit without stopping the container |
| `Ctrl-B Shift-N` | Open a **new Claude window** (runs another Claude instance) |
| `Ctrl-B n` | Next window |
| `Ctrl-B p` | Previous window |
| `Ctrl-B w` | List all windows |

**Detach vs. exit:** Pressing `Ctrl-B d` detaches your terminal but leaves the container running — Claude keeps grinding. You can reattach anytime with `yolo up <name>`. If Claude exits or you close tmux, `yolo up` will automatically create a new tmux session and reattach — no questions asked.

**Multiple Claude windows:** `Ctrl-B Shift-N` opens a new tmux window with a fresh Claude instance. This is useful when you want a second Claude to work on something else within the same worktree.

## SSH Keys

yolo forwards your SSH keys to the container so Claude can push, pull, and interact with remote repos. But we're not *reckless* about it:

1. Your `~/.ssh` directory is mounted read-only into the container
2. At startup, unencrypted private keys are loaded into `ssh-agent`
3. The private key **files are deleted** from the container filesystem
4. Only the in-memory ssh-agent remains — Claude never has access to your key files

YOLO mode, not YOLO security.

Passphrase-protected keys are skipped (they can't be loaded non-interactively). If all your keys use passphrases, you'll need to add them to your host's ssh-agent before running yolo, or use unencrypted keys.

## Configuration

### Config Sync

Your host Claude config is synced into each container:

| Host Path | What Happens |
|---|---|
| `~/.claude/` | Mounted read-only, copied into container, paths transformed |
| `~/.claude.json` | Mounted read-only, copied into container, paths transformed |
| `~/.gitconfig` | Mounted directly (read-only) |

The copy step is necessary because path references inside the JSON files need to be rewritten from your host home directory to `/home/claude`. The host files are never modified.

### Extra Mounts

Need the container to see additional host directories? Add them to `~/.yolo/mounts`, one path per line:

```
~/shared-configs
/opt/datasets
~/other-project    # comments are fine
~/scratch:rw       # read-write mount
```

Extra mounts are read-only by default. Append `:rw` to mount read-write.

### Compose Overrides

Need to expose ports, add capabilities, or tweak the container config? Drop a compose override file and yolo picks it up automatically:

```yaml
# compose.yolo.yml (in your project root)
services:
  claude:
    ports:
      - "3000:3000"
      - "8080:8080"
```

Three levels are supported — repo-local defaults that travel with the project, plus global and per-project overrides in `~/.yolo`:

| File | Scope |
|---|---|
| `compose.yolo.yml` | Project repo (commit this — it survives teardowns) |
| `~/.yolo/compose.override.yml` | All projects |
| `~/.yolo/<project>/compose.override.yml` | Single project |

All three are merged in order (repo-local first, then global, then per-project) using Docker Compose's native `-f` file merging. Changes to any override file trigger container recreation on next `yolo up`.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | API key for authentication |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth token for authentication |
| `CLAUDE_MODEL` | `claude-opus-4-6` | Which Claude model to use |
| `YOLO_HOME` | `~/.yolo` | Where yolo stores session data |
| `YOLO_LIB` | auto-detected | Directory containing Docker/compose files |
| `TZ` | auto-detected | Timezone passed to container |

### GitHub CLI

If you have `gh` installed and authenticated on the host, yolo extracts your GitHub token and passes it to the container. Claude can then use `gh` commands (create PRs, check CI, browse issues) without additional setup.

## Multi-Repo Projects

If your project directory contains multiple git repos as immediate subdirectories (a monorepo-adjacent setup), worktree mode creates a worktree for each one:

```
my-project/
├── frontend/    ← git repo
├── backend/     ← git repo
└── shared/      ← git repo
```

```bash
yolo up feat/new-api --worktree
# Creates:
#   ~/.yolo/my-project/feat-new-api/frontend/  (worktree)
#   ~/.yolo/my-project/feat-new-api/backend/   (worktree)
#   ~/.yolo/my-project/feat-new-api/shared/    (worktree)
```

Claude's working directory is set to the session base so it can navigate between repos.

In bind mode (the default, without `--worktree`), the whole project directory is mounted as-is — no worktrees, no branches, just your files.

## Session Lifecycle

Here's the full lifecycle of a session:

```
yolo up [name] [--worktree]
  │
  ├─ Resolve authentication
  ├─ Mount project directory (bind mode)
  │   — or —
  ├─ Detect git repos + create worktrees (--worktree mode)
  ├─ Generate docker-compose override
  ├─ Build & start container
  │    └─ entrypoint.sh:
  │         ├─ SSH: load keys into agent, delete key files
  │         ├─ Config: copy and transform Claude config
  │         └─ Tmux: start session with Claude Code
  ├─ Sync host config into container
  └─ Attach to tmux
       │
       │  ... you work with Claude ...
       │
  Ctrl-B d  (detach)
       │
yolo up [name]   ← reattach anytime
       │
yolo down [name]
  │
  ├─ Stop container
  └─ Clean up worktrees if any (auto-remove clean, prompt for dirty)
```

## Data Layout

```
your-project/
├── compose.yolo.yml            # repo-local compose override (optional, commit this)
└── ...

~/.yolo/
├── bin/
│   └── yolo                    # installed executable
├── lib/
│   ├── docker-compose.yml      # service definition
│   ├── Dockerfile              # image definition
│   ├── entrypoint.sh           # container startup
│   ├── tmux.conf               # tmux config
│   └── hooks/
│       ├── worktree-create.sh  # worktree creation
│       └── worktree-remove.sh  # worktree cleanup
├── mounts                      # extra mount paths (user-created)
├── compose.override.yml        # global compose override (optional)
└── <project>/
    ├── compose.override.yml    # per-project compose override (optional)
    ├── sessions.json           # worktree-to-repo mapping (worktree mode only)
    └── <session>/
        ├── docker-compose.override.yml
        └── <repo>/             # git worktree (worktree mode only)
```

## Troubleshooting

### "Error: Docker daemon is not running"

Start Docker Desktop (or the Docker daemon) and try again.

### "Error: bash 4+ required"

macOS ships with bash 3.x. Install a newer version:

```bash
brew install bash
```

Make sure the new bash is in your PATH before the system one.

### Claude's tmux session was killed

If you accidentally close Claude or press `Ctrl-C` inside tmux (instead of detaching with `Ctrl-B d`), don't sweat it. Next time you run `yolo up`, it will automatically create a new tmux session and reattach you.

### SSH keys aren't working in the container

- Passphrase-protected keys are skipped. Use unencrypted keys or pre-load them into your host ssh-agent.
- Check that your `~/.ssh` directory exists and contains key files.
- macOS-specific SSH config options (`UseKeychain`, 1Password agent) are automatically filtered out.

### Config changes aren't reflected in the container

Run `yolo up <name>` again — it auto-detects config changes and rebuilds the container if needed.

### Worktree cleanup says "commits ahead"

This means the session's branch has commits that haven't been pushed. Either push them first or use `yolo down` and answer `b` to delete the branch (losing unpushed commits).

## Development

To run from a git clone instead of an installed copy:

```bash
git clone https://github.com/sourcemagnet/yolo.git
cd yolo
./yolo up
```

When running from a clone, the script uses co-located support files directly — no install step needed.

To cut a release:

```bash
make release
```

This creates a tarball and publishes a GitHub release using `gh`.

## License

MIT
