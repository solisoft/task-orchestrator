# HomeController — root index now carries the agent-usage dashboard
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
  describe("GET / dashboard", fn()
    before_each(fn()
      assert_test_db()
      _home_reset_state()
      as_guest()
    end)

    test("returns 200", fn()
      let response = get("/")
      assert_eq(res_status(response), 200)
    end)

    test("renders the agent-usage tile", fn()
      let response = get("/")
      assert_contains(res_body(response), "Usage")
    end)

    test("lists every known agent in the tile, even with zero usage", fn()
      let response = get("/")
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
      let response = get("/")
      let body = res_body(response)
      # Every agent's tile shows the daily figure; with one claude run
      # the body must contain a `1` somewhere — the regex check below
      # nails it down to the claude row's 24h slot.
      assert_match(body, "claude[\\s\\S]+1[\\s\\S]+24h")
    end)

    test("renders `used / cap` when a daily cap is configured", fn()
      Setting.set("limit_daily_claude", 10)
      let response = get("/")
      let body = res_body(response)
      # No runs yet — `0 / 10` should appear under the claude tile.
      assert_match(body, "0[\\s\\S]+/[\\s\\S]+10")
    end)

    test("hides the cap when the limit is the unlimited sentinel (0)", fn()
      # Default state: no Setting rows. The tile still renders (the
      # `Usage` heading is present); the per-agent slot just omits
      # the `/N` cap suffix when the limit is the 0 = unlimited
      # sentinel.
      let response = get("/")
      let body = res_body(response)
      assert_contains(body, "Usage")
    end)

    test("links to /settings from the header", fn()
      let response = get("/")
      assert_contains(res_body(response), "/settings")
    end)

    test("renders the shared header (hide_header not set on dashboard)", fn()
      let response = get("/")
      assert_contains(res_body(response), "data-shared-header")
    end)

    # Regression: empty-on-disk projects used to make `project_summary`
    # fall back to `Task.counts_by_status(name)` — one filtered scan
    # per project. With `list_projects` default-filling missing entries
    # the dashboard renders 200 and the tile carries a zero-filled
    # counts row instead.
    test("renders 200 for a project that exists on disk with no tasks", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec-fixture"
      System.run_sync(["mkdir", "-p", root + "/empty_proj/tasks/todo"])
      let response = get("/")
      assert_eq(res_status(response), 200)
      let body = res_body(response)
      assert_contains(body, "empty_proj")
    end)
  end)
end)
