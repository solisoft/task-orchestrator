# HomeController — post-redesign:
#   GET /  → marketing landing (guest), Workspace inbox (auth'd)
# Workspace sections: Awaiting review, Recently failed, Long-running,
# Recently shipped — all driven by Task rows. One Task.all() scan.
fn _home_reset_state
  Task.delete_all()
  Setting.delete_all()
end

fn _home_iso_seconds_ago(seconds_ago)
  unix = DateTime.now().to_unix() - seconds_ago
  return DateTime.from_unix(unix).to_iso()
end

describe("HomeController", fn() {
  describe("GET / (anonymous landing)", fn() {
    before_each(fn() {
      assert_test_db()
      _home_reset_state()
      as_guest()
    })

    test("returns 200", fn() {
      response = get("/")
      assert_eq(res_status(response), 200)
    })

    test("renders the landing page title", fn() {
      response = get("/")
      assert_contains(res_body(response), "Task Orchestrator")
    })
  })

  describe("GET / (authenticated workspace)", fn() {
    before_each(fn() {
      assert_test_db()
      _home_reset_state()
      User.delete_all()
      User.register("wkspc@test.com", "password", "Workspace Tester")
      login("wkspc@test.com", "password")
    })

    test("returns 200 with the Workspace heading", fn() {
      response = get("/")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Workspace")
    })

    test("renders every section header even when empty", fn() {
      response = get("/")
      body = res_body(response)
      assert_contains(body, "Awaiting your review")
      assert_contains(body, "Recently failed")
      assert_contains(body, "Long-running")
      assert_contains(body, "Recently shipped")
    })

    test(
      "surfaces a task in review with a link to its task page",
      fn() {
        Task.create({
          "_key": "wkspc--rev",
          "project": "wkspc",
          "slug": "rev",
          "title": "Needs review",
          "status": "review",
          "updated_at": _home_iso_seconds_ago(60)
        })
        response = get("/")
        body = res_body(response)
        assert_contains(body, "Needs review")
        assert_contains(body, "/projects/wkspc/tasks/rev")
      }
    )

    test(
      "shows a recently failed task and skips one outside the 24h window",
      fn() {
        Task.create({
          "_key": "wkspc--fail-recent",
          "project": "wkspc",
          "slug": "fail-recent",
          "title": "Just failed",
          "status": "failed",
          "finished_at": _home_iso_seconds_ago(300),
          "updated_at": _home_iso_seconds_ago(300)
        })
        Task.create({
          "_key": "wkspc--fail-old",
          "project": "wkspc",
          "slug": "fail-old",
          "title": "Old failure",
          "status": "failed",
          "finished_at": _home_iso_seconds_ago(200000),
          "updated_at": _home_iso_seconds_ago(200000)
        })
        response = get("/")
        body = res_body(response)
        assert_contains(body, "Just failed")
      }
    )

    test(
      "flags an in-progress task running longer than 30 minutes",
      fn() {
        Task.create({
          "_key": "wkspc--long",
          "project": "wkspc",
          "slug": "long",
          "title": "Long agent",
          "status": "inprogress",
          "started_at": _home_iso_seconds_ago(2400),
          "updated_at": _home_iso_seconds_ago(2400)
        })
        Task.create({
          "_key": "wkspc--short",
          "project": "wkspc",
          "slug": "short",
          "title": "Short agent",
          "status": "inprogress",
          "started_at": _home_iso_seconds_ago(120),
          "updated_at": _home_iso_seconds_ago(120)
        })
        response = get("/")
        body = res_body(response)
        assert_contains(body, "Long agent")
      }
    )

    test(
      "renders a PR link on a shipped task with pr_url",
      fn() {
        Task.create({
          "_key": "wkspc--shipped",
          "project": "wkspc",
          "slug": "shipped",
          "title": "Shipped one",
          "status": "done",
          "finished_at": _home_iso_seconds_ago(120),
          "updated_at": _home_iso_seconds_ago(120),
          "pr_url": "https://github.com/acme/repo/pull/9"
        })
        response = get("/")
        body = res_body(response)
        assert_contains(body, "Shipped one")
        assert_contains(body, "github.com/acme/repo/pull/9")
      }
    )

    test("renders the shared header", fn() {
      response = get("/")
      assert_contains(res_body(response), "data-shared-header")
    })
  })
})
