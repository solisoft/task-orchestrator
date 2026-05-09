# task-orchestrator

Per-repo task queue + Claude Code dispatcher across every project under
`~/workspace/soli/`. Drop a `.md` task spec into a project's `tasks/todo/`,
move it to `tasks/queued/` when you want to dispatch, and a watcher fires a
headless Claude Code agent that runs `/do-task` and `/review-task` end-to-end
in a fresh git worktree, then opens a PR via `gh`.

## Layout

```
task-orchestrator/
├── bin/
│   ├── task-run            # one-shot dispatch: worktree + agents + PR
│   ├── task-watch          # inotify daemon, one per repo
│   ├── task-queue          # convenience: mv tasks/todo/X.md → tasks/queued/
│   ├── task-dashboard      # cross-repo status (CLI table)
│   └── install-watcher     # registers + starts the systemd-user unit
├── systemd/user/
│   └── task-watch@.service # template unit (instance = path-encoded repo)
├── app/                    # Soli web UI (paused; see "Status" below)
├── config/
└── README.md               # this file
```

## How a task flows

```
   you drop a .md                you mv to queued/
       │                                │
       ▼                                ▼
  tasks/todo/   ─────────────────►  tasks/queued/
                                        │
                                        ▼
                          inotifywait fires task-run
                                        │
                                        ▼
              fresh worktree + claude /do-task + /review-task
                                        │
                                ┌───────┴───────┐
                       commit produced       no commit
                                │                  │
                                ▼                  ▼
                        push + gh pr create   tasks/failed/
                                │                  │
                                └─────► state log ◄┘
```

The web UI (planned) lets you do the `mv` and edit task md content from a
browser. Until BUG-001 is resolved (see Status), use `bin/task-queue` or a
plain `mv` from the shell.

## Setup

```bash
# Dependencies
sudo apt install inotify-tools                # inotifywait
gh auth login                                 # gh CLI authenticated against your fork
claude --version                              # Claude Code CLI in PATH

# Per-repo: enable + start the watcher under systemd-user
~/workspace/soli/task-orchestrator/bin/install-watcher ~/workspace/soli/lang
~/workspace/soli/task-orchestrator/bin/install-watcher ~/workspace/soli/db
# ... repeat per repo ...

# Inspect
systemctl --user list-units 'task-watch@*'
journalctl --user -u 'task-watch@*' -f
```

## Daily use

```bash
# 1. Draft a task
$EDITOR ~/workspace/soli/lang/tasks/todo/SEC-095-foo.md

# 2. Validate + queue (fires the agent)
~/workspace/soli/task-orchestrator/bin/task-queue \
  ~/workspace/soli/lang/tasks/todo/SEC-095-foo.md

# 3. Watch progress
tail -f ~/.local/state/task-orchestrator/lang/SEC-095-foo.log

# 4. See backlog across every repo
~/workspace/soli/task-orchestrator/bin/task-dashboard
```

State files live at `~/.local/state/task-orchestrator/<repo>/<task>.{log,status,pr}`.
Active git worktrees at `~/.cache/task-orchestrator/worktrees/<repo>/<task>/`.

## Failure mode

If `/review-task` rejects the fix or the agent exits non-zero:

- The task md is moved to `tasks/failed/<name>.md` (out of `tasks/queued/` so
  it can't re-trigger).
- The full log is preserved at `~/.local/state/task-orchestrator/<repo>/<task>.log`.
- The git worktree is removed; the local branch may still exist for
  inspection (no PR was opened).

To retry, fix the task spec and `mv tasks/failed/<name>.md tasks/todo/`.

## Configuration

Environment variables read by the scripts:

| Var                       | Default                                         | Purpose |
|---------------------------|-------------------------------------------------|---------|
| `TASK_ORCH_ROOT`          | `~/workspace/soli`                              | Where the dashboard scans for projects with `tasks/` folders. |
| `TASK_ORCH_STATE`         | `~/.local/state/task-orchestrator`              | Log + status files per task run. |
| `TASK_ORCH_WORKTREES`     | `~/.cache/task-orchestrator/worktrees`          | Where agents work in isolation. Cleaned up on success. |

## Status

**Web UI is paused.** The Soli serve loader rejects multi-statement bodies in
the new `soli new` scaffold despite the same files parsing cleanly via
`soli <file.sl>`. Filed as `lang/tasks/todo/BUG-001-serve-loader-parse-error.md`
with a minimal reproducer. Resume `app/controllers/*` + `app/views/*` once
that lands.

**Working today:** `bin/task-run`, `bin/task-watch`, `bin/task-queue`,
`bin/task-dashboard`, and the systemd unit. The full dispatch loop functions
end-to-end from CLI; the web UI is the only piece blocked.
