# Run model — zombie detection in `run_current_status`.
#
# `bin/task-run` writes a `<slug>.pid` next to the .status journal at
# launch and removes it on EXIT. If the wrapper is SIGKILLed (OOM,
# `pkill -9`, parent crash) the EXIT trap doesn't fire, the .status
# stays at "running …", and without help the UI shows the run as live
# forever. The model's job is to spot that — `run_current_status`
# returns a synthesized `failed:agent died (...)` for any non-terminal
# status whose pidfile points at a dead process.
#
# These specs work directly against $TASK_ORCH_STATE on disk (pointed
# at /tmp/task-orch-spec-state by .env.test), seeding fixture files
# per scenario.

def _rs_state_dir(repo)
  let root = getenv("TASK_ORCH_STATE") ?? ""
  return root + "/" + repo
end

def _rs_reset(repo, slug)
  let dir = _rs_state_dir(repo)
  System.run_sync(["mkdir", "-p", dir])
  for ext in [".status", ".pid", ".log", ".log.jsonl", ".pr"]
    let path = dir + "/" + slug + ext
    Trusted.delete(path) rescue null
  end
  Task.delete(Task.key_for(repo, slug)) rescue null
end

def _rs_seed_done_task(repo, slug)
  Task.create({
    "_key":    Task.key_for(repo, slug),
    "project": repo,
    "slug":    slug,
    "title":   "run spec task",
    "status":  "done"
  })
end

def _rs_write_status(repo, slug, token)
  let path = _rs_state_dir(repo) + "/" + slug + ".status"
  Trusted.write(path, "2026-05-10T00:00:00+00:00\t" + token + "\n")
end

def _rs_write_pid(repo, slug, pid)
  let path = _rs_state_dir(repo) + "/" + slug + ".pid"
  Trusted.write(path, str(pid) + "\n")
end

# A PID guaranteed to be unused. `kill -0` against this returns 1.
const _rs_dead_pid = 4194303

describe("run_current_status zombie detection", fn()
  before_each(fn()
    _rs_reset("rs_repo", "rs_slug")
  end)

  test("returns nil when no status file exists", fn()
    assert_null(run_current_status("rs_repo", "rs_slug"))
  end)

  test("passes through a terminal done: token unchanged", fn()
    _rs_write_status("rs_repo", "rs_slug", "done:no-commit")
    let s = run_current_status("rs_repo", "rs_slug")
    assert_eq(s["status"], "done:no-commit")
  end)

  test("passes through a terminal failed: token unchanged", fn()
    _rs_write_status("rs_repo", "rs_slug", "failed:something")
    # Even with a dead pidfile present, terminal tokens win — they're
    # the journal's authoritative record.
    _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
    let s = run_current_status("rs_repo", "rs_slug")
    assert_eq(s["status"], "failed:something")
  end)

  test("keeps `running …` while the recorded PID is alive", fn()
    _rs_write_status("rs_repo", "rs_slug", "running /do-task")
    # Our own runner process is alive by definition.
    let self_pid = (System.run_sync(["sh", "-c", "echo $PPID"])["stdout"] ?? "").trim()
    _rs_write_pid("rs_repo", "rs_slug", self_pid)
    let s = run_current_status("rs_repo", "rs_slug")
    assert_eq(s["status"], "running /do-task")
  end)

  test("synthesizes failed:agent died when the pidfile points at a dead PID", fn()
    _rs_write_status("rs_repo", "rs_slug", "running /do-task")
    _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
    let s = run_current_status("rs_repo", "rs_slug")
    assert(s["status"].starts_with("failed:agent died"))
  end)

  test("keeps `running …` when no pidfile exists and the log is fresh", fn()
    _rs_write_status("rs_repo", "rs_slug", "running /do-task")
    # Fresh log, no pidfile — pre-pidfile launch, still healthy.
    Trusted.write(_rs_state_dir("rs_repo") + "/rs_slug.log", "alive\n")
    let s = run_current_status("rs_repo", "rs_slug")
    assert_eq(s["status"], "running /do-task")
  end)

  # Regression: a row the success path moved to `done` must not be
  # repainted `failed:agent died` just because the journal's last line
  # is non-terminal and the pidfile points at a gone process.
  test("does NOT synthesize failed: when the Task row is already 'done'", fn()
    _rs_write_status("rs_repo", "rs_slug", "running /do-task")
    _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
    _rs_seed_done_task("rs_repo", "rs_slug")
    let s = run_current_status("rs_repo", "rs_slug")
    assert_eq(s["status"], "running /do-task")
  end)
end)

describe("run_indicator", fn()
  before_each(fn()
    _rs_reset("rs_repo", "rs_slug")
  end)

  test("returns 'failed' for a zombie run", fn()
    _rs_write_status("rs_repo", "rs_slug", "running /do-task")
    _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
    assert_eq(run_indicator("rs_repo", "rs_slug"), "failed")
  end)

  # Acceptance: kanban dot stays green for a `done` row even when the
  # on-disk artefacts (zombie pid, stale `running` journal) would
  # otherwise route through the failure path.
  test("returns 'done' for a zombie run whose Task row is 'done'", fn()
    _rs_write_status("rs_repo", "rs_slug", "running /do-task")
    _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
    _rs_seed_done_task("rs_repo", "rs_slug")
    assert_eq(run_indicator("rs_repo", "rs_slug"), "done")
  end)
end)
