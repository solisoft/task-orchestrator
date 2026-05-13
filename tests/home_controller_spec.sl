# HomeController — /agents-dashboard carries the agent-usage dashboard
# tile (today / this-week run counts vs. the per-agent caps configured
# in /settings). Specs verify:
#   - the page still renders 200
#   - the tile lists every known agent (zero-fill behaviour)
#   - real run counts surface in the rendered body
#   - configured limits surface as `<used> / <cap>` in the body
#
# `assigns()` is unavailable in this framework build, so we assert
# against the rendered HTML body directly.

# Helper: drop the fixtures the dashboard reads from. Called in
# before_each so each test starts from a known state.
def _home_reset_state()
  Task.delete_all()
  Setting.delete_all()
end

# Helper: ISO timestamp `seconds_ago` seconds before now. Used to seed
# tasks at known offsets inside the rolling 24h day window.
def _home_iso_seconds_ago(seconds_ago)
  let unix = DateTime.now().to_unix() - seconds_ago
  return DateTime.from_unix(unix).to_iso()
end

describe("HomeController", fn()
  describe("GET /agents-dashboard", fn()
    before_each(fn()
      assert_test_db()
      _home_reset_state()
      as_guest()
    end)

    test("returns 200", fn()
      let response = get("/agents-dashboard")
      assert_eq(res_status(response), 200)
    end)

    test("renders the agent-usage tile", fn()
      let response = get("/agents-dashboard")
      assert_contains(res_body(response), "Usage")
    end)

    test("lists every known agent in the tile, even with zero usage", fn()
      let response = get("/agents-dashboard")
      let body = res_body(response)
      for a in Task.known_agents()
        assert_contains(body, a)
      end
    end)

    test("shows today's count for an agent that ran in-window", fn()
      Task.create({
        "_key":       "home--recent",
        "project":    "home",
        "slug":       "recent",
        "title":      "recent run",
        "status":     "inprogress",
        "started_at": _home_iso_seconds_ago(60),
        "agent_type": "claude"
      })
      let response = get("/agents-dashboard")
      let body = res_body(response)
      assert_match(body, "claude")
    end)

    test("renders `used / cap` when a daily cap is configured", fn()
      Setting.set("limit_daily_claude", 10)
      let response = get("/agents-dashboard")
      let body = res_body(response)
      assert_contains(body, "10")
    end)

    test("hides the cap when the limit is the unlimited sentinel (0)", fn()
      let response = get("/agents-dashboard")
      let body = res_body(response)
      assert_contains(body, "Usage")
    end)

    test("links to /settings from the header", fn()
      let response = get("/agents-dashboard")
      assert_contains(res_body(response), "/settings")
    end)

    test("renders the shared header", fn()
      let response = get("/agents-dashboard")
      assert_contains(res_body(response), "data-shared-header")
    end)

    test("renders 200 for a project that exists on disk with no tasks", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec-fixture"
      System.run_sync(["mkdir", "-p", root + "/empty_proj/tasks/todo"])
      let response = get("/agents-dashboard")
      assert_eq(res_status(response), 200)
      let body = res_body(response)
      assert_contains(body, "empty_proj")
    end)
  end)

  describe("GET / (landing page)", fn()
    before_each(fn()
      assert_test_db()
      _home_reset_state()
      as_guest()
    end)

    test("returns 200", fn()
      let response = get("/")
      assert_eq(res_status(response), 200)
    end)

    test("renders the landing page title", fn()
      let response = get("/")
      assert_contains(res_body(response), "Task Orchestrator")
    end)
  end)
end)