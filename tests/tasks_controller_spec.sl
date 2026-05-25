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
fn _tq_setup_workspace

  # `.env.test` points TASK_ORCH_ROOT at a fixed fixture path; we just
  # ensure the project subdirectory exists. setenv() inside the spec
  # would only affect the runner process — the test server child
  # already inherited TASK_ORCH_ROOT at spawn time.
  root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec-fixture"
  System.run_sync(["mkdir", "-p", root + "/proj/tasks/todo"])
  return root
end

# Helper: ISO timestamp `seconds_ago` seconds before now.
fn _tq_iso_seconds_ago(seconds_ago)
  unix = DateTime.now().to_unix() - seconds_ago
  return DateTime.from_unix(unix).to_iso()
end

# Seed a fresh todo task and return its slug. The task can be queued.
fn _tq_seed_todo
  Task.create({
    "_key": "proj--ready",
    "project": "proj",
    "slug": "ready",
    "title": "ready to queue",
    "status": "todo"
  })
  return "ready"
end

# All task routes now live inside the authenticate middleware scope, so
# specs must establish a session before driving them. Centralised here
# so the per-describe `before_each` blocks can call one fn instead of
# repeating the User.register + login boilerplate.
fn _tq_login_test_user
  User.delete_all()
  User.register("tq@test.com", "password", "Task Tester")
  login("tq@test.com", "password")
end

# Soli's CSRF guard rejects cookie-bearing POSTs that don't carry an
# Origin or Referer header. The test client doesn't set Origin by
# default, so we probe /login (a GET) to discover the dynamic test-
# server host, then thread it through `_tq_post(...)` on every POST.
fn _tq_origin
  probe = get("/login")
  url = probe["url"] ?? ""
  prefix = "http://"
  return url if !url.starts_with(prefix)
  rest = url.substring(prefix.length(), url.length())
  slash = rest.index_of("/")
  return prefix + rest.substring(0, slash) if slash > 0
  url
end

fn _tq_post(path, body)
  # Call the test-client `post` builtin (lookup via the global env so
  # the symbol isn't captured by the wrapper's own name).
  pst = post
  return pst(path, body, {"headers": {"Origin": _tq_origin()}})
end

fn _tq_post_hx(path, body)
  pst = post
  return pst(path, body, {"headers": {"Origin": _tq_origin(), "hx-request": "true"}})
end

# Seed a "consumed" inprogress task at `started_at` so it counts
# against the daily/weekly limit window. Used to push the budget up
# to (or past) the cap before queuing the test subject.
fn _tq_seed_consumed(suffix, started_at_iso, agent_type)
  Task.create({
    "_key": "proj--" + suffix,
    "project": "proj",
    "slug": suffix,
    "title": "consumed " + suffix,
    "status": "inprogress",
    "started_at": started_at_iso,
    "agent_type": agent_type
  })
end

describe("TasksController#queue", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test("queues a task when no limits are set", fn() {
    slug = _tq_seed_todo()
    response = _tq_post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 302)
    t = Task.find_by_slug("proj", slug)
    assert_eq(t.status, "queued")
  })

  test("queues a task when below the daily cap", fn() {
    Setting.set("agent_type", "claude")
    Setting.set("limit_daily_claude", 5)
    _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
    slug = _tq_seed_todo()
    response = _tq_post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 302)
    t = Task.find_by_slug("proj", slug)
    assert_eq(t.status, "queued")
  })

  test("rejects with 422 when the daily cap is met", fn() {
    Setting.set("agent_type", "claude")
    Setting.set("limit_daily_claude", 1)
    _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
    slug = _tq_seed_todo()
    response = _tq_post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 422)
    t = Task.find_by_slug("proj", slug)
    assert_eq(t.status, "todo")
  })

  test("rejects with 422 when the weekly cap is met", fn() {
    Setting.set("agent_type", "claude")
    Setting.set("limit_weekly_claude", 2)
    # Three runs in the past 7 days, all old enough to fall outside the
    # 24h day window — only the weekly cap should bite.
    _tq_seed_consumed("w1", _tq_iso_seconds_ago(86400 * 2), "claude")
    _tq_seed_consumed("w2", _tq_iso_seconds_ago(86400 * 3), "claude")
    slug = _tq_seed_todo()
    response = _tq_post("/projects/proj/tasks/" + slug + "/queue", {})
    assert_eq(res_status(response), 422)
    t = Task.find_by_slug("proj", slug)
    assert_eq(t.status, "todo")
  })

  test(
    "does not flip the row to queued on a 422 rejection",
    fn() {
      Setting.set("agent_type", "claude")
      Setting.set("limit_daily_claude", 1)
      _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
      slug = _tq_seed_todo()
      _tq_post("/projects/proj/tasks/" + slug + "/queue", {})
      t = Task.find_by_slug("proj", slug)
      assert_eq(t.status, "todo")
      assert_null(t.queued_at)
    }
  )

  test(
    "treats a 0 cap as unlimited even when usage is high",
    fn() {
      Setting.set("agent_type", "claude")
      Setting.set("limit_daily_claude", 0)
      _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
      _tq_seed_consumed("c2", _tq_iso_seconds_ago(120), "claude")
      slug = _tq_seed_todo()
      response = _tq_post("/projects/proj/tasks/" + slug + "/queue", {})
      assert_eq(res_status(response), 302)
    }
  )

  test(
    "counts only the effective agent, ignoring runs of other agents",
    fn() {
      Setting.set("agent_type", "claude")
      Setting.set("limit_daily_claude", 1)
      # opencode and opencode-sdk runs should NOT count against claude's
      # cap — even though there are 3 in-window runs, the limit-check
      # bucket for claude is still 0 and queueing must succeed.
      _tq_seed_consumed("o1", _tq_iso_seconds_ago(60), "opencode")
      _tq_seed_consumed("o2", _tq_iso_seconds_ago(120), "opencode")
      _tq_seed_consumed("s1", _tq_iso_seconds_ago(180), "opencode-sdk")
      slug = _tq_seed_todo()
      response = _tq_post("/projects/proj/tasks/" + slug + "/queue", {})
      assert_eq(res_status(response), 302)
    }
  )

  test(
    "HTMX request gets a 422 with an inline error fragment",
    fn() {
      Setting.set("agent_type", "claude")
      Setting.set("limit_daily_claude", 1)
      _tq_seed_consumed("c1", _tq_iso_seconds_ago(60), "claude")
      slug = _tq_seed_todo()
      response = _tq_post_hx("/projects/proj/tasks/" + slug + "/queue", {})
      assert_eq(res_status(response), 422)
      body = res_body(response)
      # The error fragment renders the board partial with the limit_error
      # banner — checking the message text confirms the partial path.
      assert_contains(body, "is at its day limit")
    }
  )
})

# Set up a real git repo at <root>/proj with a `task/<slug>` branch
# carrying one extra commit. We need a real repo (not mocks) because
# the merge UI shells out to git for branch state. `main` is checked
# out at the end so the merge action's "current branch must be main"
# guard passes.
fn _tq_setup_git_proj(slug)
  root = _tq_setup_workspace()
  proj = root + "/proj"
  cmd = "set -e; cd " + proj + " && rm -rf .git && " + "git init -q -b main && "
  + "git config user.email t@example.com && "
  + "git config user.name Test && "
  + "git commit --allow-empty -q -m initial && "
  + "git checkout -q -b task/"
  + slug
  + " && "
  + "git commit --allow-empty -q -m feature && "
  + "git checkout -q main"
  System.run_sync(["bash", "-c", cmd])
  return proj
end

# Like _tq_setup_git_proj but also adds an origin remote (bare repo)
# so Run.project_has_remote returns true. Used by tests that need to
# distinguish the remote-present vs no-remote code paths.
fn _tq_setup_git_proj_with_remote(slug)
  proj = _tq_setup_git_proj(slug)
  origin = "/tmp/merge-origin-" + slug + ".git"
  System.run_sync(["rm", "-rf", origin])
  System.run_sync(["git", "init", "-q", "--bare", origin])
  System.run_sync(["git", "-C", proj, "remote", "add", "origin", origin])
  return proj
end

describe(
  "TasksController#show with local-branch outcome",
  fn() {
    before_each(fn() {
      assert_test_db()
      Task.delete_all()
      Setting.delete_all()
      _tq_login_test_user()
    })

    test(
      "renders branch info with merge button when not merged",
      fn() {
        _tq_setup_git_proj("done-task")
        Task.create({
          "_key": "proj--done-task",
          "project": "proj",
          "slug": "done-task",
          "title": "Done task",
          "status": "review",
          "outcome": "local-branch"
        })
        response = get("/projects/proj/tasks/done-task")
        assert_eq(res_status(response), 200)
        body = res_body(response)
        assert_contains(body, "task/done-task")
        assert_contains(body, "Merge into main")
        assert_contains(body, "not merged into main")
      }
    )

    test(
      "shows merged badge and hides merge button when already merged",
      fn() {
        proj = _tq_setup_git_proj("already-merged")
        System.run_sync([
          "bash",
          "-c",
          "cd " + proj + " && git -c user.email=t@example.com -c user.name=Test "
          + "merge --no-ff --no-edit -q task/already-merged"
        ])
        Task.create({
          "_key": "proj--already-merged",
          "project": "proj",
          "slug": "already-merged",
          "title": "Already merged",
          "status": "done",
          "outcome": "local-branch"
        })
        response = get("/projects/proj/tasks/already-merged")
        assert_eq(res_status(response), 200)
        body = res_body(response)
        assert_contains(body, "merged into main")
        # The button only renders when `not merged` — its absence is the
        # signal the badge state matched.
        assert_not(body.contains("Merge into main"))
      }
    )

    test(
      "does not render branch info for done tasks without local-branch outcome",
      fn() {
        _tq_setup_git_proj("no-commit-task")
        Task.create({
          "_key": "proj--no-commit-task",
          "project": "proj",
          "slug": "no-commit-task",
          "title": "No commit",
          "status": "done",
          "outcome": "no-commit"
        })
        response = get("/projects/proj/tasks/no-commit-task")
        assert_eq(res_status(response), 200)
        body = res_body(response)
        assert_not(body.contains("Merge into main"))
      }
    )

    # Regression: legacy/manual inserts can leave a Task row with a UUID
    # `_key` that doesn't match `<project>--<slug>`. The slug-based URL
    # must still resolve via the (project, slug) fallback.
    test(
      "resolves tasks whose _key drifted off the project--slug convention",
      fn() {
        _tq_setup_git_proj("drifted")
        Task.create({
          "_key": "019e2cc2-0ce8-7c1f-8dc7-deadbeef0001",
          "project": "proj",
          "slug": "drifted-key-task",
          "title": "Drifted key task",
          "status": "todo"
        })
        response = get("/projects/proj/tasks/drifted-key-task")
        assert_eq(res_status(response), 200)
        assert_contains(res_body(response), "Drifted key task")
      }
    )

    # Regression: model classes aren't reachable from view scope, so the
    # feature link in the header has to be pre-loaded by the controller.
    test(
      "renders the feature chip for tasks linked to a feature",
      fn() {
        Feature.delete_all()
        _tq_setup_git_proj("with-feature")
        Feature.create({
          "_key": "proj--my-brief",
          "project": "proj",
          "slug": "my-brief",
          "title": "My Brief Title",
          "status": "ready"
        })
        Task.create({
          "_key": "proj--with-feature",
          "project": "proj",
          "slug": "with-feature",
          "title": "Linked task",
          "status": "todo",
          "feature_slug": "proj--my-brief"
        })
        response = get("/projects/proj/tasks/with-feature")
        assert_eq(res_status(response), 200)
        assert_contains(res_body(response), "My Brief Title")
      }
    )

    # Offline-merge UX: when the project has no `origin` remote, even
    # tasks whose outcome isn't `local-branch` still get the merge
    # button — the local branch is the only path to landing the work.
    test(
      "shows merge button for non-local-branch task when project has no remote",
      fn() {
        _tq_setup_git_proj("offline-show")
        Task.create({
          "_key": "proj--offline-show",
          "project": "proj",
          "slug": "offline-show",
          "title": "Offline show",
          "status": "review",
          "outcome": "no-commit"
        })
        response = get("/projects/proj/tasks/offline-show")
        assert_eq(res_status(response), 200)
        body = res_body(response)
        assert_contains(body, "Merge into main")
        assert_contains(body, "not merged into main")
      }
    )

    test(
      "hides commit-push button when project has no remote",
      fn() {
        _tq_setup_git_proj("no-remote-push")
        Task.create({
          "_key": "proj--no-remote-push",
          "project": "proj",
          "slug": "no-remote-push",
          "title": "No remote push",
          "status": "review",
          "outcome": "local-branch",
          "pr_url": "https://github.com/owner/repo/pull/1"
        })
        response = get("/projects/proj/tasks/no-remote-push")
        assert_eq(res_status(response), 200)
        body = res_body(response)
        # The commit-push form should not be rendered when the project has
        # no git remote — even though the task is in review with a PR URL.
        assert_not(body.contains("action=\"/projects/proj/tasks/no-remote-push/commit-push\""))
      }
    )
  }
)

describe("TasksController#merge_branch", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_login_test_user()
  })

  test(
    "merges the local branch into main on a clean main checkout",
    fn() {
      proj = _tq_setup_git_proj("merge-me")
      Task.create({
        "_key": "proj--merge-me",
        "project": "proj",
        "slug": "merge-me",
        "title": "Merge me",
        "status": "done",
        "outcome": "local-branch"
      })
      response = _tq_post("/projects/proj/tasks/merge-me/merge", {})
      assert_eq(res_status(response), 302)
      check = System.run_sync([
        "git",
        "-C",
        proj,
        "merge-base",
        "--is-ancestor",
        "task/merge-me",
        "main"
      ])
      assert_eq(check["exit_code"], 0)
    }
  )

  test(
    "rejects with 422 when the task is not done+local-branch (with remote)",
    fn() {
      # With a remote, non-local-branch tasks are NOT merge-eligible —
      # the PR is the merge path. Use the with-remote helper so the
      # eligibility check actually bites.
      _tq_setup_git_proj_with_remote("not-eligible")
      Task.create({
        "_key": "proj--not-eligible",
        "project": "proj",
        "slug": "not-eligible",
        "title": "Not eligible",
        "status": "done",
        "outcome": "no-commit"
      })
      response = _tq_post("/projects/proj/tasks/not-eligible/merge", {})
      assert_eq(res_status(response), 422)
    }
  )

  test(
    "rejects with 422 when the branch ref is missing locally",
    fn() {
      proj = _tq_setup_git_proj("ghost")
      System.run_sync([
        "git",
        "-C",
        proj,
        "branch",
        "-D",
        "task/ghost"
      ])
      Task.create({
        "_key": "proj--ghost",
        "project": "proj",
        "slug": "ghost",
        "title": "Ghost",
        "status": "done",
        "outcome": "local-branch"
      })
      response = _tq_post("/projects/proj/tasks/ghost/merge", {})
      assert_eq(res_status(response), 422)
      assert_contains(res_body(response), "not found")
    }
  )

  test("refuses to merge when the working tree is dirty", fn() {
    proj = _tq_setup_git_proj("dirty-tree")
    System.run_sync(["bash", "-c", "cd " + proj + " && echo dirty > untracked.txt"])
    Task.create({
      "_key": "proj--dirty-tree",
      "project": "proj",
      "slug": "dirty-tree",
      "title": "Dirty",
      "status": "done",
      "outcome": "local-branch"
    })
    response = _tq_post("/projects/proj/tasks/dirty-tree/merge", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "uncommitted changes")
    # Cleanup so a re-run starts clean.
    System.run_sync(["rm", "-f", proj + "/untracked.txt"])
  })

  test("refuses to merge when main is not checked out", fn() {
    proj = _tq_setup_git_proj("wrong-branch")
    System.run_sync(["git", "-C", proj, "checkout", "-q", "task/wrong-branch"])
    Task.create({
      "_key": "proj--wrong-branch",
      "project": "proj",
      "slug": "wrong-branch",
      "title": "Wrong branch",
      "status": "done",
      "outcome": "local-branch"
    })
    response = _tq_post("/projects/proj/tasks/wrong-branch/merge", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "Checkout main first")
  })

  # Offline-merge backend: when the project has no `origin` remote, the
  # merge action accepts non-local-branch tasks too (the local branch is
  # the only way to land the work).
  test("merges non-local-branch task when project has no remote", fn() {
    proj = _tq_setup_git_proj("offline-merge")
    # outcome = "no-commit" deliberately NOT "local-branch"
    Task.create({
      "_key": "proj--offline-merge",
      "project": "proj",
      "slug": "offline-merge",
      "title": "Offline merge",
      "status": "done",
      "outcome": "no-commit"
    })
    response = _tq_post("/projects/proj/tasks/offline-merge/merge", {})
    assert_eq(res_status(response), 302)
    check = System.run_sync([
      "git",
      "-C",
      proj,
      "merge-base",
      "--is-ancestor",
      "task/offline-merge",
      "main"
    ])
    assert_eq(check["exit_code"], 0)
  })

  test("rejects non-local-branch merge when project has a remote", fn() {
    _tq_setup_git_proj_with_remote("remote-reject")
    Task.create({
      "_key": "proj--remote-reject",
      "project": "proj",
      "slug": "remote-reject",
      "title": "Remote reject",
      "status": "done",
      "outcome": "no-commit"
    })
    response = _tq_post("/projects/proj/tasks/remote-reject/merge", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "only available")
  })
})

describe("TasksController#mark_done", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test(
    "transitions review task to done when no pr_url is set",
    fn() {
      Task.create({
        "_key": "proj--no-pr-review",
        "project": "proj",
        "slug": "no-pr-review",
        "title": "No PR review task",
        "status": "review"
      })
      response = _tq_post("/projects/proj/tasks/no-pr-review/mark-done", {})
      assert_eq(res_status(response), 302)
      t = Task.find_by_slug("proj", "no-pr-review")
      assert_eq(t.status, "done")
    }
  )

  test(
    "transitions review task to done when the linked PR is merged",
    fn() {
      Run.set_pr_merged_mock(true)
      Task.create({
        "_key": "proj--merged-pr",
        "project": "proj",
        "slug": "merged-pr",
        "title": "Merged PR task",
        "status": "review",
        "pr_url": "https://github.com/owner/repo/pull/1"
      })
      response = _tq_post("/projects/proj/tasks/merged-pr/mark-done", {})
      Run.set_pr_merged_mock(nil)
      assert_eq(res_status(response), 302)
      t = Task.find_by_slug("proj", "merged-pr")
      assert_eq(t.status, "done")
    }
  )

  test("returns 422 when the linked PR is not merged", fn() {
    Run.set_pr_merged_mock(false)
    Task.create({
      "_key": "proj--open-pr",
      "project": "proj",
      "slug": "open-pr",
      "title": "Open PR task",
      "status": "review",
      "pr_url": "https://github.com/owner/repo/pull/2"
    })
    response = _tq_post("/projects/proj/tasks/open-pr/mark-done", {})
    Run.set_pr_merged_mock(nil)
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "PR not merged")
    t = Task.find_by_slug("proj", "open-pr")
    assert_eq(t.status, "review")
  })

  test(
    "force-marks a review task as done even when PR is not merged",
    fn() {
      Run.set_pr_merged_mock(false)
      Task.create({
        "_key": "proj--force-pr",
        "project": "proj",
        "slug": "force-pr",
        "title": "Force PR task",
        "status": "review",
        "pr_url": "https://github.com/owner/repo/pull/3"
      })
      response = _tq_post("/projects/proj/tasks/force-pr/mark-done", {"force": "true"})
      Run.set_pr_merged_mock(nil)
      assert_eq(res_status(response), 302)
      t = Task.find_by_slug("proj", "force-pr")
      assert_eq(t.status, "done")
    }
  )

  test("returns 422 for non-review status", fn() {
    Task.create({
      "_key": "proj--todo-task",
      "project": "proj",
      "slug": "todo-task",
      "title": "Todo task",
      "status": "todo"
    })
    response = _tq_post("/projects/proj/tasks/todo-task/mark-done", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "only available for review tasks")
    t = Task.find_by_slug("proj", "todo-task")
    assert_eq(t.status, "todo")
  })

  test(
    "flips the linked feature to done when the last task closes",
    fn() {
      Feature.delete_all()
      Feature.create({
        "_key": "proj--brief",
        "project": "proj",
        "slug": "brief",
        "title": "Test brief",
        "status": "in-progress"
      })
      Task.create({
        "_key": "proj--linked",
        "project": "proj",
        "slug": "linked",
        "title": "linked review",
        "status": "review",
        "feature_slug": "proj--brief"
      })
      response = _tq_post("/projects/proj/tasks/linked/mark-done", {})
      assert_eq(res_status(response), 302)
      f = Feature.find_by_slug("proj", "brief")
      assert_eq(f.status, "done")
    }
  )
})

describe("TasksController#archive", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test("archives a done task", fn() {
    Task.create({
      "_key": "proj--archive-done",
      "project": "proj",
      "slug": "archive-done",
      "title": "Archive done",
      "status": "done"
    })
    response = _tq_post("/projects/proj/tasks/archive-done/archive", {})
    assert_eq(res_status(response), 302)
    t = Task.find_by_slug("proj", "archive-done")
    assert_eq(t.status, "archived")
  })

  test("archives a failed task", fn() {
    Task.create({
      "_key": "proj--archive-failed",
      "project": "proj",
      "slug": "archive-failed",
      "title": "Archive failed",
      "status": "failed"
    })
    response = _tq_post("/projects/proj/tasks/archive-failed/archive", {})
    assert_eq(res_status(response), 302)
    t = Task.find_by_slug("proj", "archive-failed")
    assert_eq(t.status, "archived")
  })

  test("archives a todo task", fn() {
    Task.create({
      "_key": "proj--archive-todo",
      "project": "proj",
      "slug": "archive-todo",
      "title": "Archive todo",
      "status": "todo"
    })
    response = _tq_post("/projects/proj/tasks/archive-todo/archive", {})
    assert_eq(res_status(response), 302)
    t = Task.find_by_slug("proj", "archive-todo")
    assert_eq(t.status, "archived")
  })
})

describe("TasksController#unarchive", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test("unarchives a task back to todo", fn() {
    Task.create({
      "_key": "proj--unarchive-me",
      "project": "proj",
      "slug": "unarchive-me",
      "title": "Unarchive me",
      "status": "archived"
    })
    response = _tq_post("/projects/proj/tasks/unarchive-me/unarchive", {})
    assert_eq(res_status(response), 302)
    t = Task.find_by_slug("proj", "unarchive-me")
    assert_eq(t.status, "todo")
  })

  test("returns 422 for non-archived status", fn() {
    Task.create({
      "_key": "proj--unarchive-queued",
      "project": "proj",
      "slug": "unarchive-queued",
      "title": "Unarchive queued",
      "status": "queued"
    })
    response = _tq_post("/projects/proj/tasks/unarchive-queued/unarchive", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "only available for archived")
    t = Task.find_by_slug("proj", "unarchive-queued")
    assert_eq(t.status, "queued")
  })
})

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

fn _tq_seed_plan(plan_id, status, log_text, body_text, pending_question)
  Plan.create({
    "_key": plan_id,
    "project": "proj",
    "plan_id": plan_id,
    "status": status,
    "model": "claude-sonnet-4-6",
    "prompt": "build me a thing",
    "project_path": "/tmp/proj",
    "body": body_text,
    "log": log_text,
    "pending_question": pending_question,
    "zombie": false
  })
end

describe("TasksController#create author stamping", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Plan.delete_all()
    Setting.delete_all()
    ActivityLog.delete_all()
    User.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  # Task routes are now behind the authenticate middleware — anonymous
  # POSTs get bounced to /login and the controller never runs. The
  # signed-in flow stamps the session user's email onto `task.author`.
  test("redirects anonymous POSTs to /login and creates no task", fn() {
    as_guest()
    response = _tq_post(
      "/projects/proj/tasks",
      {"title": "Anon task", "body_md": "# Anon task\n\nbody"}
    )
    assert_eq(res_status(response), 302)
    assert_contains(res_header(response, "Location") ?? "", "/login")
    assert_null(Task.find_by_slug("proj", "anon-task"))
  })

  test("stamps the signed-in user's email as author", fn() {
    response = _tq_post(
      "/projects/proj/tasks",
      {"title": "By signed in", "body_md": "# By signed in\n\nbody"}
    )
    assert_eq(res_status(response), 302)
    task = Task.find_by_slug("proj", "by-signed-in")
    assert_not_null(task)
    assert_eq(task.author ?? "", "tq@test.com")
  })

  test("persists Task.author when create receives one", fn() {
    task = Task.create({
      "_key": "proj--by-author",
      "project": "proj",
      "slug": "by-author",
      "title": "By author",
      "author": "alice@example.com",
      "status": "todo"
    })
    assert(task._errors.nil?)
    reloaded = Task.find_by_slug("proj", "by-author")
    assert_eq(reloaded.author, "alice@example.com")
  })
})

describe(
  "plan_stream_payload — model-layer builder for WS stream frames",
  fn() {
    before_each(fn() {
      assert_test_db()
      Plan.delete_all()
    })

    test(
      "connect → snapshot carrying the full log and a fresh offset",
      fn() {
        _tq_seed_plan("plan-snap", "running", "line one\nline two\n", "", nil)
        p = plan_stream_payload("plan-snap", "connect", 0)
        assert_eq(p["event"], "snapshot")
        assert_eq(p["log_chunk"], "line one\nline two\n")
        assert_eq(p["log_offset"], "line one\nline two\n".length)
        assert_eq(p["terminal"], false)
        assert_eq(p["reload"], false)
        assert_eq(p["status"], "running")
      }
    )

    test(
      "tick sends only the bytes appended past the cursor",
      fn() {
        _tq_seed_plan("plan-tick", "running", "abcde-FGHIJ", "", nil)
        p = plan_stream_payload("plan-tick", "message", 5)
        assert_eq(p["event"], "delta")
        assert_eq(p["log_chunk"], "-FGHIJ")
        assert_eq(p["log_offset"], 11)
      }
    )

    test(
      "a stale offset past EOF resends from byte 0 (truncate recovery)",
      fn() {

        # `clear_run_state` / a planner restart shrinks the .log under the
        # client's cursor. The payload resets to offset 0 so the next paint
        # matches what's actually on disk — better to re-render a few bytes
        # than skip them.
        _tq_seed_plan("plan-trunc", "running", "fresh", "", nil)
        p = plan_stream_payload("plan-trunc", "message", 9999)
        assert_eq(p["log_chunk"], "fresh")
        assert_eq(p["log_offset"], 5)
      }
    )

    test(
      "done flips terminal + reload so the client navigates after the agent finishes",
      fn() {
        _tq_seed_plan("plan-done", "done", "all done", "# spec", nil)
        p = plan_stream_payload("plan-done", "message", 0)
        assert_eq(p["terminal"], true)
        assert_eq(p["reload"], true)
      }
    )

    test(
      "failed: flips terminal but not reload (stay put for the retry CTA)",
      fn() {
        _tq_seed_plan("plan-fail", "failed:cancelled", "boom", "", nil)
        p = plan_stream_payload("plan-fail", "message", 0)
        assert_eq(p["terminal"], true)
        assert_eq(p["reload"], false)
      }
    )

    test(
      "carries the pending_question hash through verbatim",
      fn() {
        pq = {
          "id": "q1",
          "tool": "AskUserQuestion",
          "input": {"questions": [{
            "question": "Pick a path",
            "options": [{"label": "A"}, {"label": "B"}]
          }]}
        }
        _tq_seed_plan("plan-q-ws", "awaiting_question", "thinking", "", pq)
        p = plan_stream_payload("plan-q-ws", "connect", 0)
        assert_not_null(p["pending_question"])
        assert_eq(p["pending_question"]["id"], "q1")
      }
    )

    test("returns an error frame for an unknown plan", fn() {
      p = plan_stream_payload("no-such-plan", "connect", 0)
      assert_eq(p["event"], "error")
      assert_eq(p["terminal"], true)
    })

    test("normalises a negative or nil offset to 0", fn() {
      _tq_seed_plan("plan-neg", "running", "abc", "", nil)
      a = plan_stream_payload("plan-neg", "message", -5)
      assert_eq(a["log_chunk"], "abc")
      b = plan_stream_payload("plan-neg", "message", nil)
      assert_eq(b["log_chunk"], "abc")
    })
  }
)

describe("read_plan_state — DB-backed plan rehydration", fn() {
  before_each(fn() {
    assert_test_db()
    Plan.delete_all()
  })

  test(
    "returns the canonical unknown shape when the plan_id misses",
    fn() {
      s = read_plan_state("ghost")
      assert_eq(s["status"], "unknown")
      assert_eq(s["log"], "")
      assert_eq(s["model"], "claude-sonnet-4-6")
    }
  )

  test("populates fields from the Plan row", fn() {
    _tq_seed_plan("plan-read", "running", "stdout", "# body", nil)
    s = read_plan_state("plan-read")
    assert_eq(s["status"], "running")
    assert_eq(s["log"], "stdout")
    assert_eq(s["body"], "# body")
  })
})

fn _tq_worktree_path(slug)
  root = getenv("TASK_ORCH_WORKTREES") ?? "/tmp/task-orch-spec-worktree"
  root + "/proj/" + slug
end

# Create a bare origin repo and clone it into the expected
# run_worktree_path, with a `task/<slug>` branch checked out and pushed.
# Returns the worktree path. Used by the commit_push tests so the
# controller can find the worktree via run_worktree_exists / run_worktree_path.
fn _tq_setup_worktree_repo(slug)
  worktree = _tq_worktree_path(slug)
  origin = "/tmp/worktree-origin-" + slug + ".git"
  System.run_sync(["rm", "-rf", worktree, origin])
  System.run_sync(["mkdir", "-p", worktree + "/../"])
  System.run_sync(["git", "init", "-q", "--bare", origin])
  System.run_sync(["git", "init", "-q", "-b", "main", worktree])
  cmd = "cd " + worktree + " && " + "git config user.email t@example.com && "
  + "git config user.name Test && "
  + "git remote add origin "
  + origin
  + " && "
  + "git commit --allow-empty -q -m initial && "
  + "git push -q -u origin main && "
  + "git checkout -q -b task/"
  + slug
  + " && "
  + "git commit --allow-empty -q -m feature && "
  + "git push -q -u origin task/"
  + slug
  System.run_sync(["bash", "-c", cmd])
  return worktree
end

# Create a worktree repo WITHOUT an origin remote — the bare repo is
# created but the worktree never adds it. Used for the push-failure test.
fn _tq_setup_worktree_repo_no_origin(slug)
  worktree = _tq_worktree_path(slug)
  System.run_sync(["rm", "-rf", worktree])
  System.run_sync(["mkdir", "-p", worktree + "/../"])
  System.run_sync(["git", "init", "-q", "-b", "main", worktree])
  cmd = "cd " + worktree + " && " + "git config user.email t@example.com && "
  + "git config user.name Test && "
  + "git commit --allow-empty -q -m initial && "
  + "git checkout -q -b task/"
  + slug
  + " && "
  + "git commit --allow-empty -q -m feature"
  System.run_sync(["bash", "-c", cmd])
  return worktree
end

describe("TasksController#save model persistence", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test(
    "persists plan_model on task.model when the form carries one",
    fn() {
      Task.create({
        "_key": "proj--save-model",
        "project": "proj",
        "slug": "save-model",
        "title": "Save model",
        "body_md": "# original",
        "status": "todo"
      })
      response = _tq_post(
        "/projects/proj/tasks/save-model/save",
        {
          "title": "Save model",
          "body_md": "# updated",
          "plan_model": "claude-opus-4-7",
          "plan_variant": "default"
        }
      )
      assert_eq(res_status(response), 302)
      t = Task.find_by_slug("proj", "save-model")
      assert_eq(t.model, "claude-opus-4-7")
      assert_eq(t.body_md, "# updated")
    }
  )

  test(
    "stitches plan_variant onto an opencode plan_model",
    fn() {
      Task.create({
        "_key": "proj--save-stitched",
        "project": "proj",
        "slug": "save-stitched",
        "title": "Stitched",
        "body_md": "# x",
        "status": "todo"
      })
      response = _tq_post(
        "/projects/proj/tasks/save-stitched/save",
        {
          "body_md": "# x",
          "plan_model": "deepseek/deepseek-chat",
          "plan_variant": "high"
        }
      )
      assert_eq(res_status(response), 302)
      t = Task.find_by_slug("proj", "save-stitched")
      assert_eq(t.model, "deepseek/deepseek-chat:high")
    }
  )

  test(
    "leaves task.model untouched when no plan_model is submitted",
    fn() {
      Task.create({
        "_key": "proj--save-keep",
        "project": "proj",
        "slug": "save-keep",
        "title": "Keep",
        "body_md": "# x",
        "model": "claude-opus-4-7",
        "status": "todo"
      })
      response = _tq_post("/projects/proj/tasks/save-keep/save", {"body_md": "# updated"})
      assert_eq(res_status(response), 302)
      t = Task.find_by_slug("proj", "save-keep")
      assert_eq(t.model, "claude-opus-4-7")
      assert_eq(t.body_md, "# updated")
    }
  )
})

describe("TasksController#queue model override", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test(
    "persists plan_model and transitions to queued in one request",
    fn() {
      Task.create({
        "_key": "proj--queue-with-model",
        "project": "proj",
        "slug": "queue-with-model",
        "title": "Queue with model",
        "status": "todo"
      })
      response = _tq_post(
        "/projects/proj/tasks/queue-with-model/queue",
        {"plan_model": "claude-opus-4-7", "plan_variant": "default"}
      )
      assert_eq(res_status(response), 302)
      t = Task.find_by_slug("proj", "queue-with-model")
      assert_eq(t.status, "queued")
      assert_eq(t.model, "claude-opus-4-7")
    }
  )

  test(
    "queues normally and preserves task.model when no override is sent",
    fn() {
      Task.create({
        "_key": "proj--queue-no-model",
        "project": "proj",
        "slug": "queue-no-model",
        "title": "Queue without override",
        "model": "claude-haiku-4-5-20251001",
        "status": "todo"
      })
      response = _tq_post("/projects/proj/tasks/queue-no-model/queue", {})
      assert_eq(res_status(response), 302)
      t = Task.find_by_slug("proj", "queue-no-model")
      assert_eq(t.status, "queued")
      assert_eq(t.model, "claude-haiku-4-5-20251001")
    }
  )
})

describe("TasksController#show model picker", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test(
    "renders model picker pre-selected to task.model on todo tasks",
    fn() {
      Task.create({
        "_key": "proj--show-picker",
        "project": "proj",
        "slug": "show-picker",
        "title": "Show picker",
        "model": "claude-opus-4-7",
        "status": "todo"
      })
      response = get("/projects/proj/tasks/show-picker")
      assert_eq(res_status(response), 200)
      body = res_body(response)
      # The picker is in the Queue form; preselection is rendered as the
      # selected attribute on the matching option.
      assert_contains(body, "name=\"plan_model\"")
      assert_contains(body, "value=\"claude-opus-4-7\" selected")
    }
  )
})

describe("TasksController#show run-state locals", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test("todo task renders the single-column brief, no run panel", fn() {
    Task.create({
      "_key": "proj--no-run",
      "project": "proj",
      "slug": "no-run",
      "title": "No run yet",
      "status": "todo"
    })
    response = get("/projects/proj/tasks/no-run")
    assert_eq(res_status(response), 200)
    body = res_body(response)
    # The "View run log" anchor that used to point at the standalone run
    # page is gone — the run renders inline only when one exists.
    assert_not(body.contains(">View run log<"))
    # No run panel for todo tasks (no log file exists yet).
    assert_not(body.contains("id=\"run-log\""))
    assert_not(body.contains("data-stream-url=\"/ws/run-stream\""))
    # The todo path still shows the queue + archive affordances.
    assert_contains(body, "Queue &rarr; agent")
    assert_contains(body, "data-confirm=\"Archive this todo task?\"")
  })

  test("inprogress task renders the inline run panel beside the brief", fn() {
    Task.create({
      "_key": "proj--with-run",
      "project": "proj",
      "slug": "with-run",
      "title": "With run",
      "status": "inprogress"
    })
    response = get("/projects/proj/tasks/with-run")
    assert_eq(res_status(response), 200)
    body = res_body(response)
    # The run panel's structural ids prove the `runs/log` partial was
    # rendered inline on the task page. (The WS `data-stream-url` is
    # only emitted when a live status file exists on disk; controller
    # spec fixtures don't write one, so we assert on the unconditional
    # markup instead.)
    assert_contains(body, "id=\"run-panel\"")
    assert_contains(body, "id=\"run-log\"")
    assert_contains(body, "id=\"run-plan-body\"")
    # The brief still renders alongside, inside the right-side aside.
    assert_contains(body, "Task brief")
  })

  test("tail ending mid-line marks the final span as data-partial", fn() {
    Task.create({
      "_key": "proj--mid-line",
      "project": "proj",
      "slug": "mid-line",
      "title": "Mid-line tail",
      "status": "inprogress"
    })
    # Write a log whose tail ends WITHOUT a trailing newline — the partial
    # last line is the one the agent is still writing.
    state_root = Run.run_state_root() + "/proj"
    System.run_sync(["mkdir", "-p", state_root])
    Trusted.write(state_root + "/mid-line.log", "first line\nsecond line still bei")
    response = get("/projects/proj/tasks/mid-line")
    assert_eq(res_status(response), 200)
    body = res_body(response)
    # The final partial span must carry data-partial="1" so the JS
    # adopts it as `pre._partialSpan` on connect and the first WS delta
    # extends the line in place instead of starting a new visual row.
    assert_contains(body, "data-partial=\"1\"")
    assert_contains(body, "second line still bei")
    Trusted.delete(state_root + "/mid-line.log")
  })

  test("tail ending in newline emits no data-partial marker", fn() {
    Task.create({
      "_key": "proj--clean-line",
      "project": "proj",
      "slug": "clean-line",
      "title": "Clean tail",
      "status": "inprogress"
    })
    state_root = Run.run_state_root() + "/proj"
    System.run_sync(["mkdir", "-p", state_root])
    Trusted.write(state_root + "/clean-line.log", "first line\nsecond line\n")
    response = get("/projects/proj/tasks/clean-line")
    assert_eq(res_status(response), 200)
    body = res_body(response)
    assert_not(body.contains("data-partial=\"1\""))
    Trusted.delete(state_root + "/clean-line.log")
  })
})

describe("TasksController#sidebar", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test(
    "returns 200 with the sidebar fragment for an existing task",
    fn() {
      Task.create({
        "_key": "proj--sidebar-task",
        "project": "proj",
        "slug": "sidebar-task",
        "title": "Sidebar task",
        "body_md": "# Sidebar task\n\nMarkdown body content.",
        "status": "todo"
      })
      response = get("/projects/proj/tasks/sidebar-task/sidebar")
      assert_eq(res_status(response), 200)
      body = res_body(response)
      # Fragment must carry the task's title, status badge, rendered
      # markdown body, and the "View full page" escape hatch — no layout.
      assert_contains(body, "Sidebar task")
      assert_contains(body, "Markdown body content.")
      assert_contains(body, "View full page")
      assert_contains(body, "todo")
      # No outer chrome — the partial is just the fragment.
      assert_not(body.contains("<html"))
    }
  )

  test("returns 404 for an unknown slug", fn() {
    response = get("/projects/proj/tasks/does-not-exist/sidebar")
    assert_eq(res_status(response), 404)
  })

  test("returns 404 for an unknown project", fn() {
    response = get("/projects/no-such-proj/tasks/anything/sidebar")
    assert_eq(res_status(response), 404)
  })
})

describe("TasksController#commit_push", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test(
    "stages, commits, and pushes uncommitted changes in the worktree",
    fn() {
      slug = "push-me"
      _tq_setup_worktree_repo(slug)
      worktree = _tq_worktree_path(slug)
      System.run_sync([
        "bash",
        "-c",
        "cd " + worktree + " && echo 'review fix' > dirty.txt"
      ])
      Task.create({
        "_key": "proj--" + slug,
        "project": "proj",
        "slug": slug,
        "title": "Push me",
        "status": "review",
        "pr_url": "https://github.com/owner/repo/pull/1"
      })
      response = _tq_post("/projects/proj/tasks/" + slug + "/commit-push", {})
      assert_eq(res_status(response), 302)
      log = System.run_sync([
        "git",
        "-C",
        worktree,
        "log",
        "--oneline",
        "-1"
      ])
      msg = (log["stdout"] ?? "").trim()
      assert(msg.contains("fix(review)"))
    }
  )

  test("returns 422 when the task has no pr_url set", fn() {
    slug = "no-pr"
    _tq_setup_worktree_repo(slug)
    worktree = _tq_worktree_path(slug)
    System.run_sync(["bash", "-c", "cd " + worktree + " && echo 'fix' > dirty.txt"])
    Task.create({
      "_key": "proj--" + slug,
      "project": "proj",
      "slug": slug,
      "title": "No PR",
      "status": "review"
    })
    response = _tq_post("/projects/proj/tasks/" + slug + "/commit-push", {})
    assert_eq(res_status(response), 422)
    assert_contains(res_body(response), "only available for tasks with an open PR")
  })

  test(
    "returns 200 with flash when the worktree has no uncommitted changes",
    fn() {
      slug = "clean-tree"
      _tq_setup_worktree_repo(slug)
      Task.create({
        "_key": "proj--" + slug,
        "project": "proj",
        "slug": slug,
        "title": "Clean tree",
        "status": "review",
        "pr_url": "https://github.com/owner/repo/pull/1"
      })
      response = _tq_post("/projects/proj/tasks/" + slug + "/commit-push", {})
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "working tree has no uncommitted changes")
    }
  )

  test(
    "returns 200 with flash when the push fails (no remote)",
    fn() {
      slug = "push-fail"
      _tq_setup_worktree_repo_no_origin(slug)
      worktree = _tq_worktree_path(slug)
      System.run_sync([
        "bash",
        "-c",
        "cd " + worktree + " && echo 'fix' > dirty.txt"
      ])
      Task.create({
        "_key": "proj--" + slug,
        "project": "proj",
        "slug": slug,
        "title": "Push fail",
        "status": "review",
        "pr_url": "https://github.com/owner/repo/pull/1"
      })
      response = _tq_post("/projects/proj/tasks/" + slug + "/commit-push", {})
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), slug)
    }
  )
})

describe("TasksController#show tags badge", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test(
    "renders the Follow-up badge when tags contain follow_up",
    fn() {
      Task.create({
        "_key": "proj--tagged-task",
        "project": "proj",
        "slug": "tagged-task",
        "title": "Tagged task",
        "status": "todo",
        "tags": ["follow_up"]
      })
      response = get("/projects/proj/tasks/tagged-task")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Follow-up")
    }
  )

  test("omits the Follow-up badge when tags is absent", fn() {
    Task.create({
      "_key": "proj--untagged-task",
      "project": "proj",
      "slug": "untagged-task",
      "title": "Untagged task",
      "status": "todo"
    })
    response = get("/projects/proj/tasks/untagged-task")
    assert_eq(res_status(response), 200)
    assert_not(res_body(response).contains("Follow-up"))
  })

  test("omits the Follow-up badge when tags is empty", fn() {
    Task.create({
      "_key": "proj--empty-tags-task",
      "project": "proj",
      "slug": "empty-tags-task",
      "title": "Empty tags task",
      "status": "todo",
      "tags": []
    })
    response = get("/projects/proj/tasks/empty-tags-task")
    assert_eq(res_status(response), 200)
    assert_not(res_body(response).contains("Follow-up"))
  })

  test("persists tags through create and read-back", fn() {
    task = Task.create({
      "_key": "proj--readback-task",
      "project": "proj",
      "slug": "readback-task",
      "title": "Readback task",
      "status": "todo",
      "tags": ["follow_up"]
    })
    assert(task._errors.nil?)
    reloaded = Task.find_by_slug("proj", "readback-task")
    assert(reloaded.tags.present?)
    assert_eq(reloaded.tags.length(), 1)
    assert_eq(reloaded.tags[0], "follow_up")
  })
})

# Create an empty directory at the EXACT path `run_worktree_path` would
# compute for ("proj", slug). The controller's `run_worktree_exists`
# uses the same fn, so the existence check passes in tests regardless of
# whether `TASK_ORCH_WORKTREES` is exported in the runner's env.
fn _tq_setup_run_worktree(slug)
  wt = Run.run_worktree_path("proj", slug)
  System.run_sync(["mkdir", "-p", wt])
  return wt
end

describe("TasksController#code_review", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    CodeReview.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test(
    "redirects to the task page and persists a CodeReview row when the worktree exists",
    fn() {
      slug = "review-me"
      _tq_setup_run_worktree(slug)
      Task.create({
        "_key": "proj--" + slug,
        "project": "proj",
        "slug": slug,
        "title": "Review me",
        "status": "review",
        "pr_url": "https://github.com/owner/repo/pull/1"
      })
      response = _tq_post(
        "/projects/proj/tasks/" + slug + "/code-review",
        {"plan_model": "claude-sonnet-4-6", "plan_variant": "default"}
      )
      assert_eq(res_status(response), 302)
      # Non-htmx POST redirects to the task show page; the panel there
      # renders the spinner + history list driven by the WS stream.
      assert_contains(res_header(response, "Location") ?? "", "/projects/proj/tasks/" + slug)

      # A CodeReview row was persisted so the panel has something to
      # show on the next render.
      reviews = CodeReview.for_task("proj", slug)
      assert(reviews.length() > 0)
      # Tear down so a follow-up test in this file doesn't see a stale dir.
      System.run_sync([
        "rm",
        "-rf",
        Run.run_worktree_path("proj", slug)
      ])
    }
  )

  test(
    "rejects with 422 when the task is not in review status",
    fn() {
      Task.create({
        "_key": "proj--cr-not-review",
        "project": "proj",
        "slug": "cr-not-review",
        "title": "Not in review",
        "status": "todo"
      })
      response = _tq_post(
        "/projects/proj/tasks/cr-not-review/code-review",
        {"plan_model": "claude-sonnet-4-6", "plan_variant": "default"}
      )
      assert_eq(res_status(response), 422)
      assert_contains(res_body(response), "only available for review tasks")
    }
  )

  test(
    "falls through to PR-mode when the worktree is gone but a pr_url is set",
    fn() {

      # The worktree was cleaned up (merged/abandoned), but the task is
      # still in `review` and has a PR. The controller should accept the
      # request — `bin/review-run` decides the mode at runtime and falls
      # back to `gh pr diff` review.
      Task.create({
        "_key": "proj--cr-no-tree",
        "project": "proj",
        "slug": "cr-no-tree",
        "title": "No worktree, has PR",
        "status": "review",
        "pr_url": "https://github.com/owner/repo/pull/1"
      })
      response = _tq_post(
        "/projects/proj/tasks/cr-no-tree/code-review",
        {"plan_model": "claude-sonnet-4-6", "plan_variant": "default"}
      )
      assert_eq(res_status(response), 302)
      assert_contains(res_header(response, "Location") ?? "", "/projects/proj/tasks/cr-no-tree")
    }
  )

  test(
    "rejects with 422 when there is neither a worktree nor a PR",
    fn() {
      Task.create({
        "_key": "proj--cr-no-tree-no-pr",
        "project": "proj",
        "slug": "cr-no-tree-no-pr",
        "title": "No worktree, no PR",
        "status": "review"
      })
      response = _tq_post(
        "/projects/proj/tasks/cr-no-tree-no-pr/code-review",
        {"plan_model": "claude-sonnet-4-6", "plan_variant": "default"}
      )
      assert_eq(res_status(response), 422)
      assert_contains(res_body(response), "neither")
    }
  )
})

describe("TasksController#show code-review panel", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    _tq_setup_workspace()
    _tq_login_test_user()
  })

  test(
    "renders the code-review form when the task is in review",
    fn() {
      Task.create({
        "_key": "proj--cr-panel",
        "project": "proj",
        "slug": "cr-panel",
        "title": "CR panel",
        "status": "review"
      })
      response = get("/projects/proj/tasks/cr-panel")
      assert_eq(res_status(response), 200)
      body = res_body(response)
      assert_contains(body, "Run code review")
      assert_contains(body, "/projects/proj/tasks/cr-panel/code-review")
    }
  )

  test(
    "code-review form defaults to default_review_model when task.model is unset",
    fn() {
      Setting.set("review_model", "claude-haiku-4-5-20251001")
      Setting.set("plan_model", "claude-sonnet-4-6")
      Task.create({
        "_key": "proj--cr-review-default",
        "project": "proj",
        "slug": "cr-review-default",
        "title": "CR review default",
        "status": "review"
      })
      response = get("/projects/proj/tasks/cr-review-default")
      assert_eq(res_status(response), 200)
      body = res_body(response)
      # The picker should pre-select the review_model default, not the
      # plan_model default, when the task has no per-task model.
      assert_contains(body, "value=\"claude-haiku-4-5-20251001\" selected")
    }
  )

  test(
    "code-review form keeps task.model when it is set",
    fn() {
      Task.create({
        "_key": "proj--cr-task-model",
        "project": "proj",
        "slug": "cr-task-model",
        "title": "CR task model",
        "model": "claude-opus-4-7",
        "status": "review"
      })
      response = get("/projects/proj/tasks/cr-task-model")
      assert_eq(res_status(response), 200)
      body = res_body(response)
      assert_contains(body, "value=\"claude-opus-4-7\" selected")
    }
  )

  test(
    "code-review action uses submitted plan_model when present",
    fn() {
      slug = "cr-submitted-model"
      _tq_setup_run_worktree(slug)
      Task.create({
        "_key": "proj--" + slug,
        "project": "proj",
        "slug": slug,
        "title": "CR submitted model",
        "status": "review",
        "pr_url": "https://github.com/owner/repo/pull/1"
      })
      response = _tq_post(
        "/projects/proj/tasks/" + slug + "/code-review",
        {"plan_model": "claude-opus-4-7", "plan_variant": "default"}
      )
      assert_eq(res_status(response), 302)
      # Redirects to run page — model was accepted.
      assert_contains(res_header(response, "Location") ?? "", "/projects/proj/tasks/" + slug)
      System.run_sync([
        "rm",
        "-rf",
        Run.run_worktree_path("proj", slug)
      ])
    }
  )

  test("omits the code-review form for non-review tasks", fn() {
    kept_statuses = ["todo", "queued", "inprogress", "done", "archived", "failed"]
    for status in kept_statuses
      slug = "cr-omit-" + status
      Task.delete_all()
      Task.create({
        "_key": "proj--" + slug,
        "project": "proj",
        "slug": slug,
        "title": "CR omit " + status,
        "status": status
      })
      response = get("/projects/proj/tasks/" + slug)
      assert_eq(res_status(response), 200)
      body = res_body(response)
      assert_not(body.contains("Run code review"))
    end
  })
})
