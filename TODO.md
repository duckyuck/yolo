# TODO

## Persist conversation history across container rebuilds

Container rebuilds wipe `/home/claude/.claude/projects`, losing Claude Code conversation history. Fix by adding a per-session named Docker volume for the projects dir.

**Approach:** In the `docker-compose.override.yml` generated per session, add a named volume like `yolo-{project}-{session}-projects` mounted at `/home/claude/.claude/projects`. Named volumes survive container removal, so `--continue` will find prior conversations even after image rebuilds.

## Fix garbled output when copying with mouse in Ghostty after Ctrl-Q

After Ctrl-B Shift-Q shutdown, the terminal shows garbled ANSI escape sequences. Likely tmux not cleaning up terminal state before the container is removed.

## Show bind/worktree mode in status/ps

`yolo status` and `yolo ps` should display whether each session is in bind or worktree mode.
