# Agent-run state.
#
# `bin/task-run` writes per-task artifacts under
#   $TASK_ORCH_STATE/<repo>/<slug>.{log,status,pr}
#
# `<slug>.status` is an append-only `<iso>\t<status>` log; the most
# recent line is the current state. Possible status tokens:
#   starting | preparing worktree | running /do-task | running /review-task
#   pushing branch | opening PR | done:<pr_url> | failed:<reason>
#
# This model exposes read-only views of those files for the UI.

fn run_state_root()
  let custom = getenv("TASK_ORCH_STATE")
  if custom != nil and custom != ""
    return custom
  end
  let home = getenv("HOME")
  if home == nil or home == ""
    return "/home/olivier.bonnaure@delupay.com/.local/state/task-orchestrator"
  end
  return home + "/.local/state/task-orchestrator"
end

fn run_log_path(repo, slug)
  run_state_root() + "/" + repo + "/" + slug + ".log"
end

fn run_status_path(repo, slug)
  run_state_root() + "/" + repo + "/" + slug + ".status"
end

fn run_pr_path(repo, slug)
  run_state_root() + "/" + repo + "/" + slug + ".pr"
end

fn run_pid_path(repo, slug)
  run_state_root() + "/" + repo + "/" + slug + ".pid"
end

# Mirror of `bin/task-run`'s worktree layout: $TASK_ORCH_WORKTREES (or
# ~/.cache/task-orchestrator/worktrees) → <repo>/<slug>. Used by the
# resume action to refuse early when there's nothing to resume into.
# Keep in sync with the `worktree_root=` line in `bin/task-run`.
fn run_worktree_path(repo, slug)
  let custom = getenv("TASK_ORCH_WORKTREES")
  let root = ""
  if custom != nil and custom != ""
    root = custom
  else
    let home = getenv("HOME") ?? ""
    root = home + "/.cache/task-orchestrator/worktrees"
  end
  root + "/" + repo + "/" + slug
end

fn run_worktree_exists(repo, slug)
  Trusted.is_dir(run_worktree_path(repo, slug))
end

# nil  = no pidfile (run never launched, finished cleanly, or pre-pidfile launch).
# true = the recorded PID is still alive.
# false = pidfile present but the process is gone — the wrapper got SIGKILLed
#        before it could write `failed:` to the status journal.
fn _run_pid_alive(repo, slug)
  let path = run_pid_path(repo, slug)
  if not Trusted.exists(path)
    return nil
  end
  let pid = (Trusted.read(path) rescue "").trim()
  if pid == ""
    return nil
  end
  let res = System.run_sync(["kill", "-0", pid]) rescue { "exit_code": 1 }
  res["exit_code"] == 0
end

# Seconds since the run's .log was last modified, or nil if it isn't
# stat-able. Fallback heartbeat for runs launched before the pidfile
# convention shipped (no .pid on disk to probe).
fn _run_log_age_seconds(repo, slug)
  let path = run_log_path(repo, slug)
  if not Trusted.exists(path)
    return nil
  end
  let res = System.run_sync(["stat", "-c", "%Y", path])
  if res["exit_code"] != 0
    return nil
  end
  let mtime = (res["stdout"] ?? "").trim().to_int() rescue nil
  if mtime == nil
    return nil
  end
  DateTime.now().to_unix() - mtime
end

fn _is_terminal_status(token)
  token.starts_with("done:") or token.starts_with("failed:")
end

# Most recent status line, or nil if no run has happened.
fn run_current_status(repo, slug)
  let path = run_status_path(repo, slug)
  if not Trusted.exists(path)
    return nil
  end
  let body = Trusted.read(path)
  let lines = body.split("\n")
  let last = ""
  for line in lines
    if line != ""
      last = line
    end
  end
  if last == ""
    return nil
  end
  let parts = last.split("\t")
  if parts.length < 2
    return nil
  end
  let at = parts[0]
  let token = parts[1]

  # Zombie detection: the journal says we're mid-flight, but the
  # wrapper bash is gone. Synthesize `failed:` so run_indicator and
  # the status pill flip — without rewriting the on-disk journal,
  # which a manual reaper / re-queue path is responsible for.
  if not _is_terminal_status(token)
    let alive = _run_pid_alive(repo, slug)
    if alive == false
      return { "at": at, "status": "failed:agent died (no live process)" }
    end
    if alive == nil
      let age = _run_log_age_seconds(repo, slug)
      if age != nil and age > 600
        return { "at": at,
                 "status": "failed:agent died (no heartbeat for " + str(age / 60) + "m)" }
      end
    end
  end

  { "at": at, "status": token }
end

# Tail the last N bytes of the log. Returns "" if the log doesn't exist
# (e.g. task hasn't been queued yet).
fn run_log_tail(repo, slug, max_bytes)
  let path = run_log_path(repo, slug)
  if not Trusted.exists(path)
    return ""
  end
  let body = Trusted.read(path)
  if body.length <= max_bytes
    return body
  end
  body.substring(body.length - max_bytes, body.length)
end

# Path to the per-task raw JSON-lines transcript. The .log next to it is
# the human-rendered view (post-`_stream-format.jq`); this is the source.
fn run_log_jsonl_path(repo, slug)
  run_log_path(repo, slug) + ".jsonl"
end

# Latest TodoWrite payload from the run's raw stream, or [] if no todo
# event has been seen. Each entry is the agent's hash — typically
# `{ "content", "status", "priority"|"activeForm" }` — passed through as-
# is so the view can pick what to render.
#
# Strategy: read the last 1 MiB of the .jsonl tail and scan forward. The
# tail is a cheap bound that still catches the most recent TodoWrite for
# any active run; if the file is shorter, we scan all of it. Older
# events outside the window are intentionally invisible — the panel
# shows the agent's *current* plan, not a history.
fn run_latest_todos(repo, slug)
  let path = run_log_jsonl_path(repo, slug)
  if not Trusted.exists(path)
    return []
  end
  let body = Trusted.read(path) rescue ""
  if body == ""
    return []
  end
  let max_bytes = 1048576
  if body.length > max_bytes
    body = body.substring(body.length - max_bytes, body.length)
  end
  let lines = body.split("\n")
  let latest = []
  let i = 0
  while i < lines.length
    let line = lines[i]
    if line != ""
      let obj = JSON.parse(line) rescue nil
      if obj != nil
        let todos = _extract_todos_from_event(obj)
        if todos != nil
          latest = todos
        end
      end
    end
    i = i + 1
  end
  latest
end

# Pull a todos array out of a single stream event, recognising both the
# claude (nested `assistant.message.content[]`) and opencode (flat
# `tool_use` with `.part.tool == "todowrite"`) shapes. Returns nil if
# the event isn't a TodoWrite call.
fn _extract_todos_from_event(obj)
  let kind = obj["type"] ?? ""
  if kind == "tool_use"
    let part = obj["part"] ?? {}
    let tool = part["tool"] ?? ""
    if tool == "todowrite"
      let state = part["state"] ?? {}
      let input = state["input"] ?? {}
      return input["todos"]
    end
    return nil
  end
  if kind == "assistant"
    let msg = obj["message"] ?? {}
    let content = msg["content"] ?? []
    let i = 0
    while i < content.length
      let c = content[i]
      let c_type = c["type"] ?? ""
      let c_name = c["name"] ?? ""
      if c_type == "tool_use" and c_name == "TodoWrite"
        let input = c["input"] ?? {}
        return input["todos"]
      end
      i = i + 1
    end
    return nil
  end
  return nil
end

# PR URL if `task-run` opened one, else nil.
fn run_pr_url(repo, slug)
  let path = run_pr_path(repo, slug)
  if not Trusted.exists(path)
    return nil
  end
  Trusted.read(path).strip()
end

# Check whether a GitHub PR has been merged. Shells out to `gh` CLI;
# returns false when the command fails (e.g. unauthenticated, PR not
# found, network flake) so the caller can decide how to handle it.
fn pr_merged(pr_url)
  let mock = getenv("_TASK_ORCH_PR_MERGED_MOCK")
  if mock == "true"
    return true
  end
  if mock == "false"
    return false
  end
  let res = System.run_sync([
    "gh", "pr", "view", pr_url,
    "--json", "merged",
    "-q", ".merged"
  ])
  if res["exit_code"] != 0
    return false
  end
  (res["stdout"] ?? "").trim() == "true"
end

# A short status token for the kanban indicator: nil / running / done / failed.
fn run_indicator(repo, slug)
  let s = run_current_status(repo, slug)
  if s == nil
    return nil
  end
  let token = s["status"]
  if token.starts_with("done:")
    return "done"
  end
  if token.starts_with("failed:")
    return "failed"
  end
  return "running"
end

# Branch name `bin/task-run` opens for a task. Kept in sync with the
# `branch="task/${slug}"` line in that script — change both at once or
# the merge UI on the task page won't find the ref.
fn task_branch_name(slug)
  "task/" + slug
end

# Local default branch for the project — `main` if it exists, else
# `master`. Mirrors the fallback `bin/task-run` does in local-only
# mode so the merge UI agrees with what the runner branched off of.
fn project_main_branch(project_path)
  if _git_branch_exists(project_path, "main")
    return "main"
  end
  if _git_branch_exists(project_path, "master")
    return "master"
  end
  return "main"
end

fn _git_branch_exists(project_path, branch)
  let res = System.run_sync([
    "git", "-C", project_path,
    "show-ref", "--verify", "--quiet",
    "refs/heads/" + branch
  ])
  res["exit_code"] == 0
end

# Does the per-task branch (`task/<slug>`) exist locally?
fn task_branch_exists(project_path, slug)
  _git_branch_exists(project_path, task_branch_name(slug))
end

# Has the per-task branch been merged into the project's main branch?
# Uses `merge-base --is-ancestor` so a branch that's been
# squash/rebased into main still reads as merged when the tip's
# commits are reachable. Returns false if either ref is missing.
fn task_branch_merged(project_path, slug)
  let main = project_main_branch(project_path)
  if not task_branch_exists(project_path, slug)
    return false
  end
  let res = System.run_sync([
    "git", "-C", project_path,
    "merge-base", "--is-ancestor",
    task_branch_name(slug), main
  ])
  res["exit_code"] == 0
end

fn project_current_branch(project_path)
  let res = System.run_sync([
    "git", "-C", project_path,
    "rev-parse", "--abbrev-ref", "HEAD"
  ])
  if res["exit_code"] != 0
    return ""
  end
  (res["stdout"] ?? "").trim()
end

# `true` when there are uncommitted changes (staged, unstaged, or
# untracked). We treat an unparseable response as dirty — the merge
# guard refuses to act if it can't prove the tree is clean.
fn project_worktree_dirty(project_path)
  let res = System.run_sync([
    "git", "-C", project_path,
    "status", "--porcelain"
  ])
  if res["exit_code"] != 0
    return true
  end
  (res["stdout"] ?? "").trim() != ""
end

# Merge `task/<slug>` into the project's main branch with `--no-ff`
# so the per-task branch stays visible in `git log --graph`. Refuses
# to act unless main is currently checked out AND the working tree
# is clean — we will not switch branches or stash for the user.
# Returns `{ "ok": true }` or `{ "ok": false, "error": <reason> }`.
fn merge_task_branch(project_path, slug)
  let main = project_main_branch(project_path)
  let branch = task_branch_name(slug)
  let current = project_current_branch(project_path)
  if current != main
    return { "ok": false,
             "error": "current branch is '" + current + "', not '" + main +
                      "'. Checkout " + main + " first." }
  end
  if project_worktree_dirty(project_path)
    return { "ok": false,
             "error": "working tree has uncommitted changes — commit or stash first." }
  end
  let res = System.run_sync([
    "git", "-C", project_path,
    "merge", "--no-ff", "--no-edit", branch
  ])
  if res["exit_code"] != 0
    System.run_sync(["git", "-C", project_path, "merge", "--abort"]) rescue null
    let err = ((res["stderr"] ?? "") + (res["stdout"] ?? "")).trim()
    if err == ""
      err = "git merge exited " + str(res["exit_code"])
    end
    return { "ok": false, "error": err }
  end
  return { "ok": true }
end

# Wipe every on-disk artefact from a previous run for this task —
# .log, .log.jsonl, .status, .pr — so a re-queue starts from a clean
# slate. The DB row's transient fields are reset by `Task.unqueue!()`
# on the model side; this is the filesystem half.
fn clear_run_state(repo, slug)
  for path in [
    run_log_path(repo, slug),
    run_log_path(repo, slug) + ".jsonl",
    run_status_path(repo, slug),
    run_pr_path(repo, slug),
    run_pid_path(repo, slug)
  ]
    if Trusted.exists(path)
      Trusted.delete(path) rescue System.run_sync(["rm", "-f", path])
    end
  end
end
