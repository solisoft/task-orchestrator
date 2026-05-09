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
│   ├── task-dispatch       # solidb-driven dispatcher (live-query loop)
│   ├── task-watch          # inotify daemon, one per repo
│   ├── task-queue          # convenience: flips tasks/todo/X.md → queued
│   ├── task-dashboard      # cross-repo status (CLI table)
│   ├── ingest-todos        # backfills filesystem todos into solidb
│   ├── install-watcher     # registers + starts the systemd-user unit
│   └── install-skills      # syncs the `/do-task` + `/review-task` skills
├── systemd/user/
│   └── task-watch@.service # template unit (instance = path-encoded repo)
├── app/                    # Soli web UI — kanban, task editor, run viewer
│   ├── controllers/        # home, projects, tasks, runs, debug
│   ├── helpers/            # view + run-state helpers
│   ├── middleware/
│   ├── models/             # Task < Model (solidb-backed)
│   └── views/              # ERB-style .html.slv templates
├── config/
│   ├── application.sl      # boot-time framework toggles
│   └── routes.sl           # / · /projects/:name · /docs · …
├── db/
│   └── migrations/         # solidb migrations
├── tests/                  # *_spec.sl, run with `soli test`
├── public/                 # compiled CSS/JS
└── README.md               # this file
```

> Browsing the app live? Run `soli serve . --dev` and open
> [`/docs`](http://localhost:5011/docs) for a rendered Getting Started
> tour of the same material.

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

The web UI is the recommended way to drive this loop: open a project's
kanban, draft or edit a task spec, and click `Queue → agent` to flip the
row to `queued` (HTMX swaps the kanban in place). The CLI flow with
`bin/task-queue` and a plain `mv` keeps working for keybindings and
scripts.

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

**Web UI is live.** The Soli MVC scaffold under `app/` runs end-to-end
under `soli serve . --dev`: the home page lists every project under
`TASK_ORCH_ROOT`, each project has a five-column kanban (`todo / queued
/ in-progress / review / done`), tasks are editable as markdown, and
the run viewer streams the dispatcher's log fragment via HTMX polling.
The historical `BUG-001-serve-loader-parse-error.md` blocker is no
longer relevant.

**Working today:** `bin/task-run`, `bin/task-dispatch`, `bin/task-watch`,
`bin/task-queue`, `bin/task-dashboard`, the systemd-user unit, and the
full Soli web UI under `app/`. The dispatch loop runs end-to-end from
either the browser (preferred) or the CLI.

**In-app docs.** Run `soli serve . --dev` and open
[`/docs`](http://localhost:5011/docs) for a rendered Getting Started
tour of this README aimed at first-time users landing on the app.
