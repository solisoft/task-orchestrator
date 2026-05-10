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

# Set up a real git repo at <root>/proj with a `task/<slug>` branch
# carrying one extra commit. We need a real repo (not mocks) because
# the merge UI shells out to git for branch state. `main` is checked
# out at the end so the merge action's "current branch must be main"
# guard passes.
def _tq_setup_git_proj(slug)
  let root = _tq_setup_workspace()
  let proj = root + "/proj"
  let cmd = "set -e; cd " + proj + " && rm -rf .git && " +
            "git init -q -b main && " +
            "git config user.email t@example.com && " +
            "git config user.name Test && " +
            "git commit --allow-empty -q -m initial && " +
            "git checkout -q -b task/" + slug + " && " +
            "git commit --allow-empty -q -m feature && " +
            "git checkout -q main"
  System.run_sync(["bash", "-c", cmd])
  return proj
end

describe("TasksController#show with local-branch outcome", fn()
  before_each(fn()
    Task.delete_all()
    Setting.delete_all()
    as_guest()
  end)

  test("renders branch info with merge button when not merged", fn()
    _tq_setup_git_proj("done-task")
    Task.create({
      "_key":    "proj--done-task",
      "project": "proj",
      "slug":    "done-task",
      "title":   "Done task",
      "status":  "done",
      "outcome": "local-branch"
    })
    let response = get("/projects/proj/tasks/done-task")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "task/done-task")
    assert_contains(body, "Merge into main")
    assert_contains(body, "not merged into main")
  end)

  test("shows merged badge and hides merge button when already merged", fn()
    let proj = _tq_setup_git_proj("already-merged")
    System.run_sync(["bash", "-c",
      "cd " + proj + " && git -c user.email=t@example.com -c user.name=Test " +
      "merge --no-ff --no-edit -q task/already-merged"])
    Task.create({
      "_key":    "proj--already-merged",
      "project": "proj",
      "slug":    "already-merged",
      "title":   "Already merged",
      "status":  "done",
      "outcome": "local-branch"
    })
    let response = get("/projects/proj/tasks/already-merged")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "merged into main")
    # The button only renders when `not merged` — its absence is the
    # signal the badge state matched.
    assert_not_contains(body, "Merge into main")
  end)

  test("does not render branch info for done tasks without local-branch outcome", fn()
    _tq_setup_git_proj("no-commit-task")
    Task.create({
      "_key":    "proj--no-commit-task",
      "project": "proj",
      "slug":    "no-commit-task",
      "title":   "No commit",
      "status":  "done",
      "outcome": "no-commit"
    })
    let response = get("/projects/proj/tasks/no-commit-task")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_not_contains(body, "Merge into main")
  end)
end)

describe("TasksController#merge_branch", fn()
  before_each(fn()
    Task.delete_all()
    Setting.delete_all()
    as_guest()
  end)

  test("merges the local branch into main on a clean main checkout", fn()
    let proj = _tq_setup_git_proj("merge-me")
    Task.create({
      "_key":    "proj--merge-me",
      "project": "proj",
      "slug":    "merge-me",
      "title":   "Merge me",
      "status":  "done",
      "outcome": "local-branch"
    })
    let response = post("/projects/proj/tasks/merge-me/merge", {})
    assert_eq(res_status(response), 302)
    let check = System.run_sync(["git", "-C", proj,
      "merge-base", "--is-ancestor", "task/merge-me", "main"])
    assert_eq(check["exit_code"], 0)
  end)

  test("rejects with 422 when the task is not done+local-branch", fn()
    _tq_setup_git_proj("not-eligible")
    Task.create({
      "_key":    "proj--not-eligible",
      "project": "proj",
      "slug":    "not-eligible",
      "title":   "Not eligible",
      "status":  "done",
      "outcome": "no-commit"
    })
    let response = post("/projects/proj/tasks/not-eligible/merge", {})
    assert_eq(res_status(response), 422)
  end)

  test("rejects with 422 when the branch ref is missing locally", fn()
    let proj = _tq_setup_git_proj("ghost")
    System.run_sync(["git", "-C", proj, "branch", "-D", "task/ghost"])
    Task.create({
      "_key":    "proj--ghost",
      "project": "proj",
      "slug":    "ghost",
      "title":   "Ghost",
      "status":  "done",
      "outcome": "local-branch"
    })
    let response = post("/projects/proj/tasks/ghost/merge", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "not found")
  end)

  test("refuses to merge when the working tree is dirty", fn()
    let proj = _tq_setup_git_proj("dirty-tree")
    System.run_sync(["bash", "-c",
      "cd " + proj + " && echo dirty > untracked.txt"])
    Task.create({
      "_key":    "proj--dirty-tree",
      "project": "proj",
      "slug":    "dirty-tree",
      "title":   "Dirty",
      "status":  "done",
      "outcome": "local-branch"
    })
    let response = post("/projects/proj/tasks/dirty-tree/merge", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "uncommitted changes")
    # Cleanup so a re-run starts clean.
    System.run_sync(["rm", "-f", proj + "/untracked.txt"])
  end)

  test("refuses to merge when main is not checked out", fn()
    let proj = _tq_setup_git_proj("wrong-branch")
    System.run_sync(["git", "-C", proj, "checkout", "-q", "task/wrong-branch"])
    Task.create({
      "_key":    "proj--wrong-branch",
      "project": "proj",
      "slug":    "wrong-branch",
      "title":   "Wrong branch",
      "status":  "done",
      "outcome": "local-branch"
    })
    let response = post("/projects/proj/tasks/wrong-branch/merge", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "Checkout main first")
  end)
end)
