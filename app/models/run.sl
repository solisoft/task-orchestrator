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
  {
    "at": parts[0],
    "status": parts[1]
  }
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

# PR URL if `task-run` opened one, else nil.
fn run_pr_url(repo, slug)
  let path = run_pr_path(repo, slug)
  if not Trusted.exists(path)
    return nil
  end
  Trusted.read(path).strip()
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

# Wipe every on-disk artefact from a previous run for this task —
# .log, .log.jsonl, .status, .pr — so a re-queue starts from a clean
# slate. The DB row's transient fields are reset by `Task.unqueue!()`
# on the model side; this is the filesystem half.
fn clear_run_state(repo, slug)
  for path in [
    run_log_path(repo, slug),
    run_log_path(repo, slug) + ".jsonl",
    run_status_path(repo, slug),
    run_pr_path(repo, slug)
  ]
    if Trusted.exists(path)
      Trusted.delete(path) rescue System.run_sync(["rm", "-f", path])
    end
  end
end
