# TasksController — covers the agent-usage limit enforcement on the
# `queue` action. The action must:
#   - succeed (302 + status flip to "queued") when within the cap
#   - fail (422 + status stays "todo") when at the cap
#   - check the daily AND weekly caps independently
#   - resolve the effective agent via the per-task `agent_type` first
#     and fall back to the global `Setting.get("agent_type")` second
#
# The "queue" action's project lookup goes through `find_project`,
# which reads the host filesystem for a real `<root>/<name>/tasks/`
# directory. We therefore use `TASK_ORCH_ROOT` to point at a tempdir
# in `before_each` and seed it with a `<project>/tasks/todo` folder so
# the controller sees a valid project.

def _tq_setup_workspace()
  # `.env.test` points TASK_ORCH_ROOT at a fixed fixture path; we just
  # ensure the project subdirectory exists. setenv() inside the spec
  # would only affect the runner process — the test server child
  # already inherited TASK_ORCH_ROOT at spawn time.
  let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec-fixture"
  System.run_sync(["mkdir", "-p", root + "/proj/tasks/todo"])
  return root
end

# Helper: ISO timestamp `seconds_ago` seconds before now.
def _tq_iso_seconds_ago(seconds_ago)
  let unix = DateTime.now().to_unix() - seconds_ago
  return DateTime.from_unix(unix).to_iso()
end

# Seed a fresh todo task and return its slug. The task can be queued.
def _tq_seed_todo()
  Task.create({
    "_key":    "proj--ready",
    "project": "proj",
    "slug":    "ready",
    "title":   "ready to queue",
    "status":  "todo"
  })
  return "ready"
end

# Seed a "consumed" inprogress task at `started_at` so it counts
# against the daily/weekly limit window. Used to push the budget up
# to (or past) the cap before queuing the test subject.
def _tq_seed_consumed(suffix, started_at_iso, agent_type)
  Task.create({
    "_key":       "proj--" + suffix,
    "project":    "proj",
    "slug":       suffix,
    "title":      "consumed " + suffix,
    "status":     "inprogress",
    "started_at": started_at_iso,
    "agent_type": agent_type
  })
end

describe("TasksController#create", fn()
  before_each(fn()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("persists review_model when provided", fn()
    let response = post("/projects/proj/tasks", {
      "body_md": "# Test task\n\nDo something",
      "review_model": "claude-sonnet-4-20250514"
    })
    assert_eq(res_status(response), 302)
    let task = Task.find_by_slug("proj", "test-task")
    assert_not_null(task)
    assert_eq(task.review_model, "claude-sonnet-4-20250514")
  end)

  test("stores empty review_model when not provided", fn()
    let response = post("/projects/proj/tasks", {
      "body_md": "# No review model\n\nDo something"
    })
    assert_eq(res_status(response), 302)
    let task = Task.find_by_slug("proj", "no-review-model")
    assert_not_null(task)
    assert_eq(task.review_model, "")
  end)
end)

describe("TasksController#save", fn()
  before_each(fn()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("updates review_model on save", fn()
    let slug = _tq_seed_todo()
    let response = post("/projects/proj/tasks/" + slug + "/save", {
      "review_model": "claude-sonnet-4-20250514"
    })
    assert_eq(res_status(response), 302)
    let task = Task.find_by_slug("proj", slug)
    assert_eq(task.review_model, "claude-sonnet-4-20250514")
  end)

  test("allows a task with reviewing status to validate", fn()
    let task = Task.create({
      "_key":    "proj--review-test",
      "project": "proj",
      "slug":    "review-test",
      "title":   "Review test",
      "body_md": "# Review test",
      "status":  "reviewing"
    })
    assert_null(task._errors)
    assert_eq(task.status, "reviewing")
  end)
end)

describe("TasksController#queue", fn()
  before_each(fn()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("queues a task when no limits are set", fn()
    let slug = _tq_seed_todo()
    let response = post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", slug)
    assert_eq(t.status, "queued")
  end)

  test("queues a task when below the daily cap", fn()
    Setting.set("agent_type", "claude")
    Setting.set("limit_daily_claude", 5)
    _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
    let slug = _tq_seed_todo()
    let response = post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", slug)
    assert_eq(t.status, "queued")
  end)

  test("rejects with 422 when the daily cap is met", fn()
    Setting.set("agent_type", "claude")
    Setting.set("limit_daily_claude", 1)
    _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
    let slug = _tq_seed_todo()
    let response = post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 422)
    let t = Task.find_by_slug("proj", slug)
    assert_eq(t.status, "todo")
  end)

  test("rejects with 422 when the weekly cap is met", fn()
    Setting.set("agent_type", "claude")
    Setting.set("limit_weekly_claude", 2)
    # Three runs in the past 7 days, all old enough to fall outside the
    # 24h day window — only the weekly cap should bite.
    _tq_seed_consumed("w1", _tq_iso_seconds_ago(86400 * 2), "claude")
    _tq_seed_consumed("w2", _tq_iso_seconds_ago(86400 * 3), "claude")
    let slug = _tq_seed_todo()
    let response = post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 422)
    let t = Task.find_by_slug("proj", slug)
    assert_eq(t.status, "todo")
  end)

  test("does not flip the row to queued on a 422 rejection", fn()
    Setting.set("agent_type", "claude")
    Setting.set("limit_daily_claude", 1)
    _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
    let slug = _tq_seed_todo()
    post("/projects/proj/tasks/" + slug + "/queue", {})
    let t = Task.find_by_slug("proj", slug)
    assert_eq(t.status, "todo")
    assert_null(t.queued_at)
  end)

  test("treats a 0 cap as unlimited even when usage is high", fn()
    Setting.set("agent_type", "claude")
    Setting.set("limit_daily_claude", 0)
    _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
    _tq_seed_consumed("c2", _tq_iso_seconds_ago(120), "claude")
    let slug = _tq_seed_todo()
    let response = post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 302)
  end)

  test("counts only the effective agent, ignoring runs of other agents", fn()
    Setting.set("agent_type", "claude")
    Setting.set("limit_daily_claude", 1)
    # opencode and opencode-sdk runs should NOT count against claude's
    # cap — even though there are 3 in-window runs, the limit-check
    # bucket for claude is still 0 and queueing must succeed.
    _tq_seed_consumed("o1", _tq_iso_seconds_ago(60), "opencode")
    _tq_seed_consumed("o2", _tq_iso_seconds_ago(120), "opencode")
    _tq_seed_consumed("s1", _tq_iso_seconds_ago(180), "opencode-sdk")
    let slug = _tq_seed_todo()
    let response = post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 302)
  end)

  test("HTMX request gets a 422 with an inline error fragment", fn()
    Setting.set("agent_type", "claude")
    Setting.set("limit_daily_claude", 1)
    _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
    let slug = _tq_seed_todo()
    let response = post("/projects/proj/tasks/" + slug + "/queue", {}, {
      "headers": { "hx-request": "true" }
    })
    assert_eq(res_status(response), 422)
    let body = res_body(response)
    # The error fragment renders the board partial with the limit_error
    # banner — checking the message text confirms the partial path.
    assert_contains(body, "is at its day limit")
  end)
end)
