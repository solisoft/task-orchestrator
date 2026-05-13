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

# Helper: write `body` to the run's .log file inside the spec fixture.
def _rs_write_log(repo, slug, body)
  let path = _rs_state_dir(repo) + "/" + slug + ".log"
  Trusted.write(path, body)
end

describe("run_log_delta — byte-cursor diffing for the WS stream", fn()
  before_each(fn()
    _rs_reset("rs_repo", "rs_slug")
  end)

  test("returns chunk='' and offset=0 when the .log doesn't exist yet", fn()
    let d = run_log_delta("rs_repo", "rs_slug", 0)
    assert_eq(d["chunk"], "")
    assert_eq(d["offset"], 0)
  end)

  test("returns the full body at offset 0", fn()
    _rs_write_log("rs_repo", "rs_slug", "hello world")
    let d = run_log_delta("rs_repo", "rs_slug", 0)
    assert_eq(d["chunk"], "hello world")
    assert_eq(d["offset"], 11)
  end)

  test("returns only bytes appended past the cursor", fn()
    _rs_write_log("rs_repo", "rs_slug", "hello world")
    let d = run_log_delta("rs_repo", "rs_slug", 6)
    assert_eq(d["chunk"], "world")
    assert_eq(d["offset"], 11)
  end)

  test("returns chunk='' when the cursor is at EOF (no new bytes)", fn()
    _rs_write_log("rs_repo", "rs_slug", "frozen")
    let d = run_log_delta("rs_repo", "rs_slug", 6)
    assert_eq(d["chunk"], "")
    assert_eq(d["offset"], 6)
  end)

  test("resends from byte 0 when the file shrank under the cursor (truncate recovery)", fn()
    _rs_write_log("rs_repo", "rs_slug", "short")
    let d = run_log_delta("rs_repo", "rs_slug", 9999)
    assert_eq(d["chunk"], "short")
    assert_eq(d["offset"], 5)
  end)
end)

describe("run_stream_payload — model-layer builder for the WS frame", fn()
  before_each(fn()
    _rs_reset("rs_repo", "rs_slug")
  end)

  test("connect → snapshot carrying the entire log and current status", fn()
    _rs_write_log("rs_repo", "rs_slug", "boot...\nready\n")
    _rs_write_status("rs_repo", "rs_slug", "running /do-task")
    # Pidfile points at our own runner so `run_current_status` skips
    # the zombie synthesis path and reports the journal token verbatim.
    let self_pid = (System.run_sync(["sh", "-c", "echo $PPID"])["stdout"] ?? "").trim()
    _rs_write_pid("rs_repo", "rs_slug", self_pid)
    let p = run_stream_payload("rs_repo", "rs_slug", "connect", 0)
    assert_eq(p["event"], "snapshot")
    assert_eq(p["log_chunk"], "boot...\nready\n")
    assert_eq(p["log_offset"], "boot...\nready\n".length)
    assert_eq(p["terminal"], false)
    assert_eq(p["status"]["status"], "running /do-task")
  end)

  test("tick → delta with only the bytes appended past the cursor", fn()
    _rs_write_log("rs_repo", "rs_slug", "abcdefghij")
    let p = run_stream_payload("rs_repo", "rs_slug", "message", 4)
    assert_eq(p["event"], "delta")
    assert_eq(p["log_chunk"], "efghij")
    assert_eq(p["log_offset"], 10)
  end)

  test("flips terminal=true once the journal reaches done:", fn()
    _rs_write_log("rs_repo", "rs_slug", "all green\n")
    _rs_write_status("rs_repo", "rs_slug", "done:https://example.invalid/pr/1")
    let p = run_stream_payload("rs_repo", "rs_slug", "message", 0)
    assert_eq(p["terminal"], true)
  end)

  test("flips terminal=true once the journal reaches failed:", fn()
    _rs_write_log("rs_repo", "rs_slug", "oh no\n")
    _rs_write_status("rs_repo", "rs_slug", "failed:oom")
    let p = run_stream_payload("rs_repo", "rs_slug", "message", 0)
    assert_eq(p["terminal"], true)
  end)

  test("a stale offset past EOF resends from byte 0", fn()
    _rs_write_log("rs_repo", "rs_slug", "rewound")
    let p = run_stream_payload("rs_repo", "rs_slug", "message", 9999)
    assert_eq(p["log_chunk"], "rewound")
    assert_eq(p["log_offset"], 7)
  end)

  test("normalises a negative or nil offset to 0", fn()
    _rs_write_log("rs_repo", "rs_slug", "xyz")
    let a = run_stream_payload("rs_repo", "rs_slug", "message", -1)
    assert_eq(a["log_chunk"], "xyz")
    let b = run_stream_payload("rs_repo", "rs_slug", "message", nil)
    assert_eq(b["log_chunk"], "xyz")
  end)
end)
