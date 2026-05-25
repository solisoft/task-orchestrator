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
    assert_test_db()
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

# Like _tq_setup_git_proj but also adds an origin remote (bare repo)
# so project_has_remote returns true. Used by tests that need to
# distinguish the remote-present vs no-remote code paths.
def _tq_setup_git_proj_with_remote(slug)
  let proj = _tq_setup_git_proj(slug)
  let origin = "/tmp/merge-origin-" + slug + ".git"
  System.run_sync(["rm", "-rf", origin])
  System.run_sync(["git", "init", "-q", "--bare", origin])
  System.run_sync(["git", "-C", proj, "remote", "add", "origin", origin])
  return proj
end

describe("TasksController#show with local-branch outcome", fn()
  before_each(fn()
    assert_test_db()
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
      "status":  "review",
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
    assert_not(body.contains("Merge into main"))
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
    assert_not(body.contains("Merge into main"))
  end)

  test("shows merge button for non-local-branch task when project has no remote", fn()
    _tq_setup_git_proj("offline-show")
    Task.create({
      "_key":    "proj--offline-show",
      "project": "proj",
      "slug":    "offline-show",
      "title":   "Offline show",
      "status":  "review",
      "outcome": "no-commit"
    })
    let response = get("/projects/proj/tasks/offline-show")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "Merge into main")
    assert_contains(body, "not merged into main")
  end)

  test("hides commit-push button when project has no remote", fn()
    _tq_setup_git_proj("no-remote-push")
    Task.create({
      "_key":    "proj--no-remote-push",
      "project": "proj",
      "slug":    "no-remote-push",
      "title":   "No remote push",
      "status":  "review",
      "outcome": "local-branch",
      "pr_url":  "https://github.com/owner/repo/pull/1"
    })
    let response = get("/projects/proj/tasks/no-remote-push")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    # The commit-push form should not be rendered when the project has
    # no git remote — even though the task is in review with a PR URL.
    assert_not(body.contains("action=\"/projects/proj/tasks/no-remote-push/commit-push\""))
  end)
end)

describe("TasksController#merge_branch", fn()
  before_each(fn()
    assert_test_db()
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
    _tq_setup_git_proj_with_remote("not-eligible")
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

  test("merges non-local-branch when project has no remote (offline mode)", fn()
    let proj = _tq_setup_git_proj("offline-merge")
    # outcome = "no-commit" deliberately NOT "local-branch"
    Task.create({
      "_key":    "proj--offline-merge",
      "project": "proj",
      "slug":    "offline-merge",
      "title":   "Offline merge",
      "status":  "done",
      "outcome": "no-commit"
    })
    let response = post("/projects/proj/tasks/offline-merge/merge", {})
    assert_eq(res_status(response), 302)
    let check = System.run_sync(["git", "-C", proj,
      "merge-base", "--is-ancestor", "task/offline-merge", "main"])
    assert_eq(check["exit_code"], 0)
  end)

  test("rejects non-local-branch merge when project has a remote", fn()
    let proj = _tq_setup_git_proj_with_remote("remote-reject")
    Task.create({
      "_key":    "proj--remote-reject",
      "project": "proj",
      "slug":    "remote-reject",
      "title":   "Remote reject",
      "status":  "done",
      "outcome": "no-commit"
    })
    let response = post("/projects/proj/tasks/remote-reject/merge", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "only available")
  end)
end)

describe("TasksController#mark_done", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("transitions review task to done when no pr_url is set", fn()
    Task.create({
      "_key":    "proj--no-pr-review",
      "project": "proj",
      "slug":    "no-pr-review",
      "title":   "No PR review task",
      "status":  "review"
    })
    let response = post("/projects/proj/tasks/no-pr-review/mark-done", {})
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "no-pr-review")
    assert_eq(t.status, "done")
  end)

  test("transitions review task to done when the linked PR is merged", fn()
    set_pr_merged_mock(true)
    Task.create({
      "_key":    "proj--merged-pr",
      "project": "proj",
      "slug":    "merged-pr",
      "title":   "Merged PR task",
      "status":  "review",
      "pr_url":  "https://github.com/owner/repo/pull/1"
    })
    let response = post("/projects/proj/tasks/merged-pr/mark-done", {})
    set_pr_merged_mock(nil)
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "merged-pr")
    assert_eq(t.status, "done")
  end)

  test("returns 422 when the linked PR is not merged", fn()
    set_pr_merged_mock(false)
    Task.create({
      "_key":    "proj--open-pr",
      "project": "proj",
      "slug":    "open-pr",
      "title":   "Open PR task",
      "status":  "review",
      "pr_url":  "https://github.com/owner/repo/pull/2"
    })
    let response = post("/projects/proj/tasks/open-pr/mark-done", {})
    set_pr_merged_mock(nil)
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "PR not merged")
    let t = Task.find_by_slug("proj", "open-pr")
    assert_eq(t.status, "review")
  end)

  test("force-marks a review task as done even when PR is not merged", fn()
    set_pr_merged_mock(false)
    Task.create({
      "_key":    "proj--force-pr",
      "project": "proj",
      "slug":    "force-pr",
      "title":   "Force PR task",
      "status":  "review",
      "pr_url":  "https://github.com/owner/repo/pull/3"
    })
    let response = post("/projects/proj/tasks/force-pr/mark-done", { "force": "true" })
    set_pr_merged_mock(nil)
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "force-pr")
    assert_eq(t.status, "done")
  end)

  test("returns 422 for non-review status", fn()
    Task.create({
      "_key":    "proj--todo-task",
      "project": "proj",
      "slug":    "todo-task",
      "title":   "Todo task",
      "status":  "todo"
    })
    let response = post("/projects/proj/tasks/todo-task/mark-done", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "only available for review tasks")
    let t = Task.find_by_slug("proj", "todo-task")
    assert_eq(t.status, "todo")
  end)

  test("flips the linked feature to done when the last task closes", fn()
    Feature.delete_all()
    Feature.create({
      "_key":    "proj--brief",
      "project": "proj",
      "slug":    "brief",
      "title":   "Test brief",
      "status":  "in-progress"
    })
    Task.create({
      "_key":         "proj--linked",
      "project":      "proj",
      "slug":         "linked",
      "title":        "linked review",
      "status":       "review",
      "feature_slug": "proj--brief"
    })
    let response = post("/projects/proj/tasks/linked/mark-done", {})
    assert_eq(res_status(response), 302)
    let f = Feature.find_by_slug("proj", "brief")
    assert_eq(f.status, "done")
  end)
end)

describe("TasksController#archive", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("archives a done task", fn()
    Task.create({
      "_key":    "proj--archive-done",
      "project": "proj",
      "slug":    "archive-done",
      "title":   "Archive done",
      "status":  "done"
    })
    let response = post("/projects/proj/tasks/archive-done/archive", {})
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "archive-done")
    assert_eq(t.status, "archived")
  end)

  test("archives a failed task", fn()
    Task.create({
      "_key":    "proj--archive-failed",
      "project": "proj",
      "slug":    "archive-failed",
      "title":   "Archive failed",
      "status":  "failed"
    })
    let response = post("/projects/proj/tasks/archive-failed/archive", {})
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "archive-failed")
    assert_eq(t.status, "archived")
  end)

  test("archives a todo task", fn()
    Task.create({
      "_key":    "proj--archive-todo",
      "project": "proj",
      "slug":    "archive-todo",
      "title":   "Archive todo",
      "status":  "todo"
    })
    let response = post("/projects/proj/tasks/archive-todo/archive", {})
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "archive-todo")
    assert_eq(t.status, "archived")
  end)
end)

describe("TasksController#unarchive", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("unarchives a task back to todo", fn()
    Task.create({
      "_key":    "proj--unarchive-me",
      "project": "proj",
      "slug":    "unarchive-me",
      "title":   "Unarchive me",
      "status":  "archived"
    })
    let response = post("/projects/proj/tasks/unarchive-me/unarchive", {})
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "unarchive-me")
    assert_eq(t.status, "todo")
  end)

  test("returns 422 for non-archived status", fn()
    Task.create({
      "_key":    "proj--unarchive-queued",
      "project": "proj",
      "slug":    "unarchive-queued",
      "title":   "Unarchive queued",
      "status":  "queued"
    })
    let response = post("/projects/proj/tasks/unarchive-queued/unarchive", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "only available for archived")
    let t = Task.find_by_slug("proj", "unarchive-queued")
    assert_eq(t.status, "queued")
  end)
end)

# --- plan_log polling shape ----------------------------------------
#
# Regression coverage for the prompt-panel-flash bug: while a plan is
# running, the polling endpoint must return ONLY the right-panel
# `_plan_stream` markup. The static "Your prompt" recap (rendered by
# `_plan_prompt`) belongs to the initial swap and must NOT appear in
# subsequent poll responses — re-rendering it on every tick is what
# made the left aside flash. When the runner flips to `done`, the
# response retargets to `#form-stage` so the whole stage swaps to the
# planned-body editor.

def _tq_seed_plan(plan_id, status, log_text, body_text, pending_question)
  Plan.create({
    "_key":             plan_id,
    "project":          "proj",
    "plan_id":          plan_id,
    "status":           status,
    "model":            "claude-sonnet-4-6",
    "prompt":           "build me a thing",
    "project_path":     "/tmp/proj",
    "body":             body_text,
    "log":              log_text,
    "pending_question": pending_question,
    "zombie":           false
  })
end

describe("TasksController#create author stamping", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Plan.delete_all()
    Setting.delete_all()
    ActivityLog.delete_all()
    User.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  # The controller reads `session_get("user_email")` directly because
  # task routes run outside the auth-middleware scope. Driving the
  # signed-in flow through the test client would force us to satisfy
  # Soli's CSRF guard (Origin/Referer must match the dynamic test-
  # server port). The `change_author` propagation onto the action
  # endpoints (queue / mark-done / archive) is covered at the model
  # layer in `activity_log_spec.sl` — same code path, zero CSRF
  # surface. Here we just check the unauthenticated branch.
  test("leaves author empty when no session is set", fn()
    let response = post("/projects/proj/tasks", {
      "title":   "Anon task",
      "body_md": "# Anon task\n\nbody"
    })
    assert_eq(res_status(response), 302)
    let task = Task.find_by_slug("proj", "anon-task")
    assert_eq(task.author ?? "", "")
  end)

  test("persists Task.author when create receives one", fn()
    let task = Task.create({
      "_key":    "proj--by-author",
      "project": "proj",
      "slug":    "by-author",
      "title":   "By author",
      "author":  "alice@example.com",
      "status":  "todo"
    })
    assert(task._errors == nil)
    let reloaded = Task.find_by_slug("proj", "by-author")
    assert_eq(reloaded.author, "alice@example.com")
  end)
end)

describe("TasksController#create plan linkage", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Plan.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("stamps task_slug on the matching plan when plan_id is in the form", fn()
    _tq_seed_plan("plan-link-1", "done", "", "# Linked", nil)
    let response = post("/projects/proj/tasks", {
      "title":        "Linked task",
      "body_md":      "# Linked task\n\nbody",
      "plan_model":   "claude-sonnet-4-6",
      "plan_variant": "default",
      "plan_id":      "plan-link-1"
    })
    assert_eq(res_status(response), 302)
    let plan = Plan.find_by_plan_id("plan-link-1")
    assert_eq(plan.task_slug, "linked-task")
    let task = Task.find_by_slug("proj", "linked-task")
    assert_not_null(task)
  end)

  test("leaves plan rows unchanged when no plan_id is in the form", fn()
    _tq_seed_plan("plan-link-2", "done", "", "# Untouched", nil)
    let response = post("/projects/proj/tasks", {
      "title":   "Standalone task",
      "body_md": "# Standalone task\n\nbody"
    })
    assert_eq(res_status(response), 302)
    let plan = Plan.find_by_plan_id("plan-link-2")
    assert_null(plan.task_slug)
  end)

  test("silently ignores an unknown plan_id", fn()
    # Stale form post (plan was deleted between render and submit). The
    # task creation itself must still succeed — the linkage is a
    # nice-to-have, not a precondition.
    let response = post("/projects/proj/tasks", {
      "title":   "Orphan task",
      "body_md": "# Orphan",
      "plan_id": "plan-does-not-exist"
    })
    assert_eq(res_status(response), 302)
    let task = Task.find_by_slug("proj", "orphan-task")
    assert_not_null(task)
  end)
end)

describe("TasksController#plan_log", fn()
  before_each(fn()
    assert_test_db()
    Plan.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("returns the plan-stream partial wired to the WebSocket stream", fn()
    _tq_seed_plan("plan-running", "running", "step 1\nstep 2", "", nil)
    let response = get("/projects/proj/tasks/plan-log/plan-running")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    # Right-panel root is present; static prompt aside is NOT.
    assert_contains(body, "id=\"plan-stream\"")
    assert_not(body.contains("Your prompt"))
    # The WS streamer is wired up via data-stream-* attrs — the markup
    # no longer drives htmx polling. The route URL itself is static
    # (Soli 1.0.3 doesn't extract :params from router_websocket paths),
    # so the resource identifier rides as data-stream-plan-id.
    assert_contains(body, "data-stream-url=\"/ws/plan-stream\"")
    assert_contains(body, "data-stream-plan-id=\"plan-running\"")
    assert_not(body.contains("hx-trigger=\"every 2s\""))
  end)

  test("omits the WS wiring and shows the question on the awaiting_question state", fn()
    let pq = {
      "id":    "q1",
      "tool":  "AskUserQuestion",
      "input": { "questions": [{ "question": "Pick one",
                                  "options":  [{ "label": "A" }, { "label": "B" }] }] }
    }
    _tq_seed_plan("plan-q", "awaiting_question", "", "", pq)
    let response = get("/projects/proj/tasks/plan-log/plan-q")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "id=\"plan-stream\"")
    assert_contains(body, "Pick one")
    assert_not(body.contains("Your prompt"))
    # The WS subscription is suppressed while a question is pending —
    # otherwise an in-flight tick can race the user's click and
    # re-render the card.
    assert_not(body.contains("data-stream-url="))
    assert_not(body.contains("hx-trigger=\"every 2s\""))
  end)

  test("returns the planned-body and retargets to #form-stage when done", fn()
    _tq_seed_plan("plan-done", "done", "", "# Done plan\n\nbody markdown\n", nil)
    let response = get("/projects/proj/tasks/plan-log/plan-done")
    assert_eq(res_status(response), 200)
    # HX-Retarget tells htmx to redirect the swap from #plan-stream
    # (the polling element) onto the outer #form-stage container, so
    # the whole stage flips to the editor view in one tick.
    assert_eq(res_header(response, "HX-Retarget"), "#form-stage")
    assert_eq(res_header(response, "HX-Reswap"), "innerHTML")
    let body = res_body(response)
    # Planned-body markup is present; the running-state stream root
    # (id="plan-stream") has been replaced.
    assert_contains(body, "Refine the draft")
    assert_not(body.contains("id=\"plan-stream\""))
  end)
end)

describe("TasksController#plan_answer", fn()
  before_each(fn()
    assert_test_db()
    Plan.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("returns only the plan-stream partial after writing the answer", fn()
    let pq = {
      "id":    "q1",
      "tool":  "AskUserQuestion",
      "input": { "questions": [{ "question": "Pick one",
                                  "options":  [{ "label": "A" }, { "label": "B" }] }] }
    }
    _tq_seed_plan("plan-ans", "awaiting_question", "", "", pq)
    let response = post("/projects/proj/tasks/plan-answer/plan-ans",
                        { "qid": "q1", "value": "A" })
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    # Right-panel-only response — the left "Your prompt" aside is NOT
    # in the answer payload, so the prompt DOM node persists across
    # the round-trip.
    assert_contains(body, "id=\"plan-stream\"")
    assert_not(body.contains("Your prompt"))
    # The answer was persisted on the plan row.
    let plan = Plan.find_by_plan_id("plan-ans")
    assert_eq(plan.pending_question["id"], "q1")
    assert_eq(plan.pending_question["value"], "A")
  end)

  test("retargets to #form-stage when the answer races the agent finishing", fn()
    _tq_seed_plan("plan-race", "done", "", "# Raced plan\n\nfinal spec\n", nil)
    let response = post("/projects/proj/tasks/plan-answer/plan-race",
                        { "qid": "q1", "value": "A" })
    assert_eq(res_status(response), 200)
    assert_eq(res_header(response, "HX-Retarget"), "#form-stage")
    assert_eq(res_header(response, "HX-Reswap"), "innerHTML")
    let body = res_body(response)
    assert_not(body.contains("id=\"plan-stream\""))
  end)

  test("rejects with 422 when qid or value is missing", fn()
    _tq_seed_plan("plan-bad", "awaiting_question", "", "", nil)
    let response = post("/projects/proj/tasks/plan-answer/plan-bad",
                        { "qid": "", "value": "A" })
    assert_eq(res_status(response), 422)
  end)
end)

describe("plan_stream_payload — model-layer builder for WS stream frames", fn()
  before_each(fn()
    assert_test_db()
    Plan.delete_all()
  end)

  test("connect → snapshot carrying the full log and a fresh offset", fn()
    _tq_seed_plan("plan-snap", "running", "line one\nline two\n", "", nil)
    let p = plan_stream_payload("plan-snap", "connect", 0)
    assert_eq(p["event"], "snapshot")
    assert_eq(p["log_chunk"], "line one\nline two\n")
    assert_eq(p["log_offset"], "line one\nline two\n".length)
    assert_eq(p["terminal"], false)
    assert_eq(p["reload"], false)
    assert_eq(p["status"], "running")
  end)

  test("tick sends only the bytes appended past the cursor", fn()
    _tq_seed_plan("plan-tick", "running", "abcde-FGHIJ", "", nil)
    let p = plan_stream_payload("plan-tick", "message", 5)
    assert_eq(p["event"], "delta")
    assert_eq(p["log_chunk"], "-FGHIJ")
    assert_eq(p["log_offset"], 11)
  end)

  test("a stale offset past EOF resends from byte 0 (truncate recovery)", fn()
    # `clear_run_state` / a planner restart shrinks the .log under the
    # client's cursor. The payload resets to offset 0 so the next paint
    # matches what's actually on disk — better to re-render a few bytes
    # than skip them.
    _tq_seed_plan("plan-trunc", "running", "fresh", "", nil)
    let p = plan_stream_payload("plan-trunc", "message", 9999)
    assert_eq(p["log_chunk"], "fresh")
    assert_eq(p["log_offset"], 5)
  end)

  test("done flips terminal + reload so the client navigates after the agent finishes", fn()
    _tq_seed_plan("plan-done", "done", "all done", "# spec", nil)
    let p = plan_stream_payload("plan-done", "message", 0)
    assert_eq(p["terminal"], true)
    assert_eq(p["reload"], true)
  end)

  test("failed: flips terminal but not reload (stay put for the retry CTA)", fn()
    _tq_seed_plan("plan-fail", "failed:cancelled", "boom", "", nil)
    let p = plan_stream_payload("plan-fail", "message", 0)
    assert_eq(p["terminal"], true)
    assert_eq(p["reload"], false)
  end)

  test("carries the pending_question hash through verbatim", fn()
    let pq = {
      "id":    "q1",
      "tool":  "AskUserQuestion",
      "input": { "questions": [{ "question": "Pick a path",
                                  "options":  [{ "label": "A" }, { "label": "B" }] }] }
    }
    _tq_seed_plan("plan-q-ws", "awaiting_question", "thinking", "", pq)
    let p = plan_stream_payload("plan-q-ws", "connect", 0)
    assert_not_null(p["pending_question"])
    assert_eq(p["pending_question"]["id"], "q1")
  end)

  test("returns an error frame for an unknown plan", fn()
    let p = plan_stream_payload("no-such-plan", "connect", 0)
    assert_eq(p["event"], "error")
    assert_eq(p["terminal"], true)
  end)

  test("normalises a negative or nil offset to 0", fn()
    _tq_seed_plan("plan-neg", "running", "abc", "", nil)
    let a = plan_stream_payload("plan-neg", "message", -5)
    assert_eq(a["log_chunk"], "abc")
    let b = plan_stream_payload("plan-neg", "message", nil)
    assert_eq(b["log_chunk"], "abc")
  end)
end)

describe("read_plan_state — DB-backed plan rehydration", fn()
  before_each(fn()
    assert_test_db()
    Plan.delete_all()
  end)

  test("returns the canonical unknown shape when the plan_id misses", fn()
    let s = read_plan_state("ghost")
    assert_eq(s["status"], "unknown")
    assert_eq(s["log"], "")
    assert_eq(s["model"], "claude-sonnet-4-6")
  end)

  test("populates fields from the Plan row", fn()
    _tq_seed_plan("plan-read", "running", "stdout", "# body", nil)
    let s = read_plan_state("plan-read")
    assert_eq(s["status"], "running")
    assert_eq(s["log"], "stdout")
    assert_eq(s["body"], "# body")
  end)
end)

def _tq_worktree_path(slug)
  let root = getenv("TASK_ORCH_WORKTREES") ?? "/tmp/task-orch-spec-worktree"
  root + "/proj/" + slug
end

# Create a bare origin repo and clone it into the expected
# run_worktree_path, with a `task/<slug>` branch checked out and pushed.
# Returns the worktree path. Used by the commit_push tests so the
# controller can find the worktree via run_worktree_exists / run_worktree_path.
def _tq_setup_worktree_repo(slug)
  let worktree = _tq_worktree_path(slug)
  let origin = "/tmp/worktree-origin-" + slug + ".git"
  System.run_sync(["rm", "-rf", worktree, origin])
  System.run_sync(["mkdir", "-p", worktree + "/../"])
  System.run_sync(["git", "init", "-q", "--bare", origin])
  System.run_sync(["git", "init", "-q", "-b", "main", worktree])
  let cmd = "cd " + worktree + " && " +
            "git config user.email t@example.com && " +
            "git config user.name Test && " +
            "git remote add origin " + origin + " && " +
            "git commit --allow-empty -q -m initial && " +
            "git push -q -u origin main && " +
            "git checkout -q -b task/" + slug + " && " +
            "git commit --allow-empty -q -m feature && " +
            "git push -q -u origin task/" + slug
  System.run_sync(["bash", "-c", cmd])
  return worktree
end

# Create a worktree repo WITHOUT an origin remote — the bare repo is
# created but the worktree never adds it. Used for the push-failure test.
def _tq_setup_worktree_repo_no_origin(slug)
  let worktree = _tq_worktree_path(slug)
  System.run_sync(["rm", "-rf", worktree])
  System.run_sync(["mkdir", "-p", worktree + "/../"])
  System.run_sync(["git", "init", "-q", "-b", "main", worktree])
  let cmd = "cd " + worktree + " && " +
            "git config user.email t@example.com && " +
            "git config user.name Test && " +
            "git commit --allow-empty -q -m initial && " +
            "git checkout -q -b task/" + slug + " && " +
            "git commit --allow-empty -q -m feature"
  System.run_sync(["bash", "-c", cmd])
  return worktree
end

describe("TasksController#save model persistence", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("persists plan_model on task.model when the form carries one", fn()
    Task.create({
      "_key":    "proj--save-model",
      "project": "proj",
      "slug":    "save-model",
      "title":   "Save model",
      "body_md": "# original",
      "status":  "todo"
    })
    let response = post("/projects/proj/tasks/save-model/save", {
      "title":        "Save model",
      "body_md":      "# updated",
      "plan_model":   "claude-opus-4-7",
      "plan_variant": "default"
    })
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "save-model")
    assert_eq(t.model, "claude-opus-4-7")
    assert_eq(t.body_md, "# updated")
  end)

  test("stitches plan_variant onto an opencode plan_model", fn()
    Task.create({
      "_key":    "proj--save-stitched",
      "project": "proj",
      "slug":    "save-stitched",
      "title":   "Stitched",
      "body_md": "# x",
      "status":  "todo"
    })
    let response = post("/projects/proj/tasks/save-stitched/save", {
      "body_md":      "# x",
      "plan_model":   "deepseek/deepseek-chat",
      "plan_variant": "high"
    })
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "save-stitched")
    assert_eq(t.model, "deepseek/deepseek-chat:high")
  end)

  test("leaves task.model untouched when no plan_model is submitted", fn()
    Task.create({
      "_key":    "proj--save-keep",
      "project": "proj",
      "slug":    "save-keep",
      "title":   "Keep",
      "body_md": "# x",
      "model":   "claude-opus-4-7",
      "status":  "todo"
    })
    let response = post("/projects/proj/tasks/save-keep/save", {
      "body_md": "# updated"
    })
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "save-keep")
    assert_eq(t.model, "claude-opus-4-7")
    assert_eq(t.body_md, "# updated")
  end)
end)

describe("TasksController#queue model override", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("persists plan_model and transitions to queued in one request", fn()
    Task.create({
      "_key":    "proj--queue-with-model",
      "project": "proj",
      "slug":    "queue-with-model",
      "title":   "Queue with model",
      "status":  "todo"
    })
    let response = post("/projects/proj/tasks/queue-with-model/queue", {
      "plan_model":   "claude-opus-4-7",
      "plan_variant": "default"
    })
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "queue-with-model")
    assert_eq(t.status, "queued")
    assert_eq(t.model, "claude-opus-4-7")
  end)

  test("queues normally and preserves task.model when no override is sent", fn()
    Task.create({
      "_key":    "proj--queue-no-model",
      "project": "proj",
      "slug":    "queue-no-model",
      "title":   "Queue without override",
      "model":   "claude-haiku-4-5-20251001",
      "status":  "todo"
    })
    let response = post("/projects/proj/tasks/queue-no-model/queue", {})
    assert_eq(res_status(response), 302)
    let t = Task.find_by_slug("proj", "queue-no-model")
    assert_eq(t.status, "queued")
    assert_eq(t.model, "claude-haiku-4-5-20251001")
  end)
end)

describe("TasksController#show model picker", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("renders model picker pre-selected to task.model on todo tasks", fn()
    Task.create({
      "_key":    "proj--show-picker",
      "project": "proj",
      "slug":    "show-picker",
      "title":   "Show picker",
      "model":   "claude-opus-4-7",
      "status":  "todo"
    })
    let response = get("/projects/proj/tasks/show-picker")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    # The picker is in the Queue form; preselection is rendered as the
    # selected attribute on the matching option.
    assert_contains(body, "name=\"plan_model\"")
    assert_contains(body, "value=\"claude-opus-4-7\" selected")
  end)
end)

describe("TasksController#sidebar", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("returns 200 with the sidebar fragment for an existing task", fn()
    Task.create({
      "_key":    "proj--sidebar-task",
      "project": "proj",
      "slug":    "sidebar-task",
      "title":   "Sidebar task",
      "body_md": "# Sidebar task\n\nMarkdown body content.",
      "status":  "todo"
    })
    let response = get("/projects/proj/tasks/sidebar-task/sidebar")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    # Fragment must carry the task's title, status badge, rendered
    # markdown body, and the "View full page" escape hatch — no layout.
    assert_contains(body, "Sidebar task")
    assert_contains(body, "Markdown body content.")
    assert_contains(body, "View full page")
    assert_contains(body, "todo")
    # No outer chrome — the partial is just the fragment.
    assert_not(body.contains("<html"))
  end)

  test("returns 404 for an unknown slug", fn()
    let response = get("/projects/proj/tasks/does-not-exist/sidebar")
    assert_eq(res_status(response), 404)
  end)

  test("returns 404 for an unknown project", fn()
    let response = get("/projects/no-such-proj/tasks/anything/sidebar")
    assert_eq(res_status(response), 404)
  end)
end)

describe("TasksController#commit_push", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("stages, commits, and pushes uncommitted changes in the worktree", fn()
    let slug = "push-me"
    _tq_setup_worktree_repo(slug)
    let worktree = _tq_worktree_path(slug)
    System.run_sync(["bash", "-c",
      "cd " + worktree + " && echo 'review fix' > dirty.txt"])
    Task.create({
      "_key":    "proj--" + slug,
      "project": "proj",
      "slug":    slug,
      "title":   "Push me",
      "status":  "review",
      "pr_url":  "https://github.com/owner/repo/pull/1"
    })
    let response = post("/projects/proj/tasks/" + slug + "/commit-push", {})
    assert_eq(res_status(response), 302)
    let log = System.run_sync(["git", "-C", worktree,
      "log", "--oneline", "-1"])
    let msg = (log["stdout"] ?? "").trim()
    assert(msg.contains("fix(review)"))
  end)

  test("returns 422 when the task has no pr_url set", fn()
    let slug = "no-pr"
    _tq_setup_worktree_repo(slug)
    let worktree = _tq_worktree_path(slug)
    System.run_sync(["bash", "-c",
      "cd " + worktree + " && echo 'fix' > dirty.txt"])
    Task.create({
      "_key":    "proj--" + slug,
      "project": "proj",
      "slug":    slug,
      "title":   "No PR",
      "status":  "review"
    })
    let response = post("/projects/proj/tasks/" + slug + "/commit-push", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "only available for tasks with an open PR")
  end)

  test("returns 200 with flash when the worktree has no uncommitted changes", fn()
    let slug = "clean-tree"
    _tq_setup_worktree_repo(slug)
    Task.create({
      "_key":    "proj--" + slug,
      "project": "proj",
      "slug":    slug,
      "title":   "Clean tree",
      "status":  "review",
      "pr_url":  "https://github.com/owner/repo/pull/1"
    })
    let response = post("/projects/proj/tasks/" + slug + "/commit-push", {})
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "working tree has no uncommitted changes")
  end)

  test("returns 200 with flash when the push fails (no remote)", fn()
    let slug = "push-fail"
    _tq_setup_worktree_repo_no_origin(slug)
    let worktree = _tq_worktree_path(slug)
    System.run_sync(["bash", "-c",
      "cd " + worktree + " && echo 'fix' > dirty.txt"])
    Task.create({
      "_key":    "proj--" + slug,
      "project": "proj",
      "slug":    slug,
      "title":   "Push fail",
      "status":  "review",
      "pr_url":  "https://github.com/owner/repo/pull/1"
    })
    let response = post("/projects/proj/tasks/" + slug + "/commit-push", {})
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), slug)
  end)
end)

describe("TasksController#show tags badge", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("renders the Follow-up badge when tags contain follow_up", fn()
    Task.create({
      "_key":    "proj--tagged-task",
      "project": "proj",
      "slug":    "tagged-task",
      "title":   "Tagged task",
      "status":  "todo",
      "tags":    ["follow_up"]
    })
    let response = get("/projects/proj/tasks/tagged-task")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "Follow-up")
  end)

  test("omits the Follow-up badge when tags is absent", fn()
    Task.create({
      "_key":    "proj--untagged-task",
      "project": "proj",
      "slug":    "untagged-task",
      "title":   "Untagged task",
      "status":  "todo"
    })
    let response = get("/projects/proj/tasks/untagged-task")
    assert_eq(res_status(response), 200)
    assert_not(res_body(response).contains("Follow-up"))
  end)

  test("omits the Follow-up badge when tags is empty", fn()
    Task.create({
      "_key":    "proj--empty-tags-task",
      "project": "proj",
      "slug":    "empty-tags-task",
      "title":   "Empty tags task",
      "status":  "todo",
      "tags":    []
    })
    let response = get("/projects/proj/tasks/empty-tags-task")
    assert_eq(res_status(response), 200)
    assert_not(res_body(response).contains("Follow-up"))
  end)

  test("persists tags through create and read-back", fn()
    let task = Task.create({
      "_key":    "proj--readback-task",
      "project": "proj",
      "slug":    "readback-task",
      "title":   "Readback task",
      "status":  "todo",
      "tags":    ["follow_up"]
    })
    assert(task._errors == nil)
    let reloaded = Task.find_by_slug("proj", "readback-task")
    assert(reloaded.tags != nil)
    assert_eq(reloaded.tags.length(), 1)
    assert_eq(reloaded.tags[0], "follow_up")
  end)
end)

# Create an empty directory at the EXACT path `run_worktree_path` would
# compute for ("proj", slug). The controller's `run_worktree_exists`
# uses the same fn, so the existence check passes in tests regardless of
# whether `TASK_ORCH_WORKTREES` is exported in the runner's env.
def _tq_setup_run_worktree(slug)
  let wt = run_worktree_path("proj", slug)
  System.run_sync(["mkdir", "-p", wt])
  return wt
end

describe("TasksController#code_review", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    CodeReview.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("redirects to the task page and persists a CodeReview row when the worktree exists", fn()
    let slug = "review-me"
    _tq_setup_run_worktree(slug)
    Task.create({
      "_key":    "proj--" + slug,
      "project": "proj",
      "slug":    slug,
      "title":   "Review me",
      "status":  "review",
      "pr_url":  "https://github.com/owner/repo/pull/1"
    })
    let response = post("/projects/proj/tasks/" + slug + "/code-review", {
      "plan_model":   "claude-sonnet-4-6",
      "plan_variant": "default"
    })
    assert_eq(res_status(response), 302)
    # Non-htmx POST redirects to the task show page; the panel there
    # renders the spinner + history list driven by the WS stream.
    assert_contains(res_header(response, "Location") ?? "",
                    "/projects/proj/tasks/" + slug)
    # A CodeReview row was persisted so the panel has something to
    # show on the next render.
    let reviews = CodeReview.for_task("proj", slug)
    assert(reviews.length() > 0)
    # Tear down so a follow-up test in this file doesn't see a stale dir.
    System.run_sync(["rm", "-rf", run_worktree_path("proj", slug)])
  end)

  test("rejects with 422 when the task is not in review status", fn()
    Task.create({
      "_key":    "proj--cr-not-review",
      "project": "proj",
      "slug":    "cr-not-review",
      "title":   "Not in review",
      "status":  "todo"
    })
    let response = post("/projects/proj/tasks/cr-not-review/code-review", {
      "plan_model":   "claude-sonnet-4-6",
      "plan_variant": "default"
    })
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "only available for review tasks")
  end)

  test("falls through to PR-mode when the worktree is gone but a pr_url is set", fn()
    # The worktree was cleaned up (merged/abandoned), but the task is
    # still in `review` and has a PR. The controller should accept the
    # request — `bin/review-run` decides the mode at runtime and falls
    # back to `gh pr diff` review.
    Task.create({
      "_key":    "proj--cr-no-tree",
      "project": "proj",
      "slug":    "cr-no-tree",
      "title":   "No worktree, has PR",
      "status":  "review",
      "pr_url":  "https://github.com/owner/repo/pull/1"
    })
    let response = post("/projects/proj/tasks/cr-no-tree/code-review", {
      "plan_model":   "claude-sonnet-4-6",
      "plan_variant": "default"
    })
    assert_eq(res_status(response), 302)
    assert_contains(res_header(response, "Location") ?? "",
                    "/projects/proj/tasks/cr-no-tree")
  end)

  test("rejects with 422 when there is neither a worktree nor a PR", fn()
    Task.create({
      "_key":    "proj--cr-no-tree-no-pr",
      "project": "proj",
      "slug":    "cr-no-tree-no-pr",
      "title":   "No worktree, no PR",
      "status":  "review"
    })
    let response = post("/projects/proj/tasks/cr-no-tree-no-pr/code-review", {
      "plan_model":   "claude-sonnet-4-6",
      "plan_variant": "default"
    })
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "neither")
  end)
end)

describe("TasksController#show code-review panel", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    as_guest()
  end)

  test("renders the code-review form when the task is in review", fn()
    Task.create({
      "_key":    "proj--cr-panel",
      "project": "proj",
      "slug":    "cr-panel",
      "title":   "CR panel",
      "status":  "review"
    })
    let response = get("/projects/proj/tasks/cr-panel")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "Run code review")
    assert_contains(body, "/projects/proj/tasks/cr-panel/code-review")
  end)

  test("code-review form defaults to default_review_model when task.model is unset", fn()
    Setting.set("review_model", "claude-haiku-4-5-20251001")
    Setting.set("plan_model", "claude-sonnet-4-6")
    Task.create({
      "_key":    "proj--cr-review-default",
      "project": "proj",
      "slug":    "cr-review-default",
      "title":   "CR review default",
      "status":  "review"
    })
    let response = get("/projects/proj/tasks/cr-review-default")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    # The picker should pre-select the review_model default, not the
    # plan_model default, when the task has no per-task model.
    assert_contains(body, "value=\"claude-haiku-4-5-20251001\" selected")
  end)

  test("code-review form keeps task.model when it is set", fn()
    Task.create({
      "_key":    "proj--cr-task-model",
      "project": "proj",
      "slug":    "cr-task-model",
      "title":   "CR task model",
      "model":   "claude-opus-4-7",
      "status":  "review"
    })
    let response = get("/projects/proj/tasks/cr-task-model")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "value=\"claude-opus-4-7\" selected")
  end)

  test("code-review action uses submitted plan_model when present", fn()
    let slug = "cr-submitted-model"
    _tq_setup_run_worktree(slug)
    Task.create({
      "_key":    "proj--" + slug,
      "project": "proj",
      "slug":    slug,
      "title":   "CR submitted model",
      "status":  "review",
      "pr_url":  "https://github.com/owner/repo/pull/1"
    })
    let response = post("/projects/proj/tasks/" + slug + "/code-review", {
      "plan_model":   "claude-opus-4-7",
      "plan_variant": "default"
    })
    assert_eq(res_status(response), 302)
    # Redirects to run page — model was accepted.
    assert_contains(res_header(response, "Location") ?? "",
                    "/projects/proj/tasks/" + slug)
    System.run_sync(["rm", "-rf", run_worktree_path("proj", slug)])
  end)

  test("omits the code-review form for non-review tasks", fn()
    let kept_statuses = ["todo", "queued", "inprogress", "done", "archived", "failed"]
    for status in kept_statuses
      let slug = "cr-omit-" + status
      Task.delete_all()
      Task.create({
        "_key":    "proj--" + slug,
        "project": "proj",
        "slug":    slug,
        "title":   "CR omit " + status,
        "status":  status
      })
      let response = get("/projects/proj/tasks/" + slug)
      assert_eq(res_status(response), 200)
      let body = res_body(response)
      assert_not(body.contains("Run code review"))
    end
  end)
end)
