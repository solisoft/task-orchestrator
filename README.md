# task-orchestrator

A queue + dispatcher that runs Claude Code (or opencode) headlessly across
every repo under `~/workspace/soli/`. Drop a spec into a project's task
list, mark it `queued`, and a single global daemon picks it up, spins a
fresh git worktree, runs `/do-task` then `/review-task`, and either opens
a PR or leaves a local branch for you to merge.

Tasks are stored as rows in **solidb** — there is no per-repo file-based
queue. The web UI under `app/` is the recommended driver; the CLI helpers
exist for keybindings and scripts.

## Layout

```
task-orchestrator/
├── bin/
│   ├── task-dispatch         # global daemon (Bun) — solidb live-query → claim → exec task-run
│   ├── task-run              # one-shot dispatch: worktree + agents + PR
│   ├── task-queue            # CLI: flip a row's status from "todo" to "queued"
│   ├── task-dashboard        # CLI: cross-repo status table
│   ├── ingest-todos          # one-shot: backfill filesystem todos into solidb
│   ├── install-dispatcher    # registers + starts the global systemd-user unit
│   ├── plan-run / plan-run-agent.ts # background "Plan it" agent runner
│   └── _stream-format.jq     # pretty-prints claude/opencode JSON streams into the run log
├── systemd/user/
│   └── task-dispatch.service # one global unit (no per-repo instances)
├── app/                      # Soli MVC web UI — kanban, editor, run viewer
├── config/
│   ├── application.sl
│   └── routes.sl
├── db/migrations/            # solidb migrations
├── tests/                    # *_spec.sl, run with `soli test`
└── public/                   # compiled CSS/JS
```

`.claude/skills/{do-task,review-task,plan-task}` ship in this repo and
get copied into each worktree at dispatch time. They are the source of
truth for what `/do-task` and `/review-task` do — there is no per-project
copy to keep in sync.

> Browsing the app live? Run `soli serve . --dev` and open
> [`/docs`](http://localhost:5011/docs) for the rendered Getting Started
> tour.

## How a task flows

```
   you draft a spec                         you click "Queue → agent"
   in the kanban editor                     (or: bin/task-queue <slug>)
       │                                              │
       ▼                                              ▼
  status="todo"  ──────────────────────►   status="queued"  (row in solidb)
                                                    │
                                                    ▼
                       task-dispatch (Bun, one global daemon)
                       sees the row via WS live-query, CAS-claims it
                                                    │
                                                    ▼
                   status="inprogress"  →  spawn bin/task-run
                                                    │
                                                    ▼
                fresh worktree off origin/main (or local main/master),
                seed tasks/todo/<slug>.md + .claude/skills/{do,review}-task,
                run claude (or opencode) /do-task → /review-task
                                                    │
                                ┌───────────────────┼────────────────────┐
                       commit produced           no commit           agent crashed
                                │                   │                     │
                                ▼                   ▼                     ▼
                  push + gh pr create     status="done"           status="failed"
                  status="review"         (no-code-change         (worktree kept
                  pr_url stored            close)                  for inspection)
```

The dispatcher is one process for the whole workspace — there is no
per-repo watcher anymore. The DB row is the single source of truth for
status; the on-disk `.log`/`.status` files are journals for the run
viewer.

## Dependencies

| Tool                | Used by                              | Notes                                                  |
|---------------------|--------------------------------------|--------------------------------------------------------|
| **bun**             | `bin/task-dispatch`                  | Runs the TS daemon. `mise install bun` or upstream.    |
| **bash**, **git**   | `bin/task-run`, `bin/task-queue`, …  | Standard.                                               |
| **jq**              | `bin/task-run`, stream formatter     | Builds DB update payloads + filters JSON streams.       |
| **curl**            | `bin/task-run`, `bin/task-queue`     | Talks to the solidb HTTP API.                           |
| **solidb**          | everything                           | The DB that holds the `tasks` collection. Default `http://localhost:6745`. |
| **claude**          | `bin/task-run` (default agent)        | When the row's `model` is a `claude-*` id or empty.    |
| **opencode**        | `bin/task-run` (alternate agent)      | When the row's `model` is `provider/model[:variant]`. |
| **gh**              | `bin/task-run`                       | Only required for repos with an `origin` remote (PR creation). |

## Setup

```bash
# 1. Make sure the dependencies above are on PATH.
bun --version && claude --version && jq --version && curl --version

# 2. Configure solidb credentials. The dispatcher reads them from .env
#    in this repo (gitignored). Default values match a local solidb dev
#    install on :6745.
cat > .env <<EOF
SOLIDB_HOST=http://localhost:6745
SOLIDB_DATABASE=tasks
SOLIDB_USERNAME=admin
SOLIDB_PASSWORD=admin
EOF

# 3. Run migrations (creates the `tasks` collection).
soli db:migrate up

# 4. (Optional) Backfill any existing tasks/todo/*.md scattered across
#    sibling repos into the DB.
bin/ingest-todos

# 5. Install + start the global dispatcher under systemd-user.
bin/install-dispatcher

# 6. Run the web UI.
soli serve . --dev      # http://localhost:5011

# Inspect the dispatcher
systemctl --user status task-dispatch.service
journalctl --user -u task-dispatch.service -f
tail -f ~/.local/state/task-orchestrator/dispatcher.log
```

## Daily use

The web UI is the intended path: open a project, draft / refine a spec
in the kanban editor (the "Plan it" button kicks `/plan-task` to
structure rough notes into a spec), pick the agent + effort, and click
**Queue → agent**. The row flips to `queued`, the dispatcher sees it
within a frame, and the run viewer streams the log live.

CLI fallback:

```bash
# Flip a task to queued (DB-side; the file path form is still accepted
# for old keybindings, but is parsed into project/slug — the file move
# itself is no longer what triggers anything).
bin/task-queue lang/SEC-095-foo

# Watch a specific run
tail -f ~/.local/state/task-orchestrator/lang/SEC-095-foo.log

# Cross-repo status
bin/task-dashboard
```

State files: `~/.local/state/task-orchestrator/<repo>/<slug>.{log,log.jsonl,status,pr}`
plus `~/.local/state/task-orchestrator/dispatcher.log`. Active worktrees:
`~/.cache/task-orchestrator/worktrees/<repo>/<slug>/`.

## Failure mode

If the agent exits non-zero, /review-task rejects, or anything else trips
`fail()` in `bin/task-run`:

- The row's `status` is set to `"failed"` with a `failure_reason`.
- The full log survives at `~/.local/state/task-orchestrator/<repo>/<slug>.log`.
- The git worktree is **kept** for inspection (not torn down on the
  failure path) — clean it up by hand once you've looked, or rerun the
  task (the worktree is removed at the start of every dispatch).
- For repos with `origin`: nothing is pushed, no PR is opened.
- For local-only repos: the `task/<slug>` branch may still exist with
  partial work; inspect with `git -C <repo> log task/<slug> --not main`.

Killing a running task with SIGTERM (e.g. `systemctl --user stop` or
`kill <pid>`) trips the trap in `bin/task-run`, which flips the row
back to `queued` so the dispatcher will retry on the next frame.

## Configuration

Environment variables read by the scripts (load order: process env →
`.env` at this repo's root → defaults):

| Var                    | Default                                 | Purpose                                                      |
|------------------------|-----------------------------------------|--------------------------------------------------------------|
| `SOLIDB_HOST`          | `http://localhost:6745`                 | solidb base URL.                                             |
| `SOLIDB_DATABASE`      | `tasks`                                 | DB name holding the `tasks` collection.                      |
| `SOLIDB_USERNAME`      | `admin`                                 | Basic-auth user.                                             |
| `SOLIDB_PASSWORD`      | `admin`                                 | Basic-auth password.                                         |
| `TASK_ORCH_ROOT`       | `~/workspace/soli`                      | Where the dashboard / ingest scan for projects.              |
| `TASK_ORCH_STATE`      | `~/.local/state/task-orchestrator`      | Per-task `.log` / `.status` / `.pr` + `dispatcher.log`.      |
| `TASK_ORCH_WORKTREES`  | `~/.cache/task-orchestrator/worktrees`  | Where `task-run` builds its scratch trees.                   |

## Per-task model selection

The DB row's `model` field decides which agent runs `/do-task` and
`/review-task`:

- Empty → `claude` with its default model.
- `claude-opus-4-7` / `claude-sonnet-4-6` / `claude-haiku-4-5-20251001` →
  `claude --model <id>`.
- `provider/model` (e.g. `deepseek/deepseek-v4-pro`) → `opencode run -m`.
- `provider/model:variant` (e.g. `deepseek/deepseek-v4-pro:low`) →
  `opencode run -m <provider/model> --variant <variant>`. Variants are
  the provider-specific reasoning effort levels (`low` / `medium` /
  `high` / `minimal` / `max`); supported by reasoning models on
  OpenRouter and similar.

The form in the web UI exposes both the agent dropdown and an "Effort"
select that stitches the `:variant` suffix on opencode picks; the
"Effort" choice is ignored when the agent is a claude SDK id.
