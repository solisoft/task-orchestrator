# PlansController — /plans lists completed plan specs on disk that haven't
# been converted to tasks. We seed plan directories + files under the
# default TASK_ORCH_STATE to simulate the on-disk state.

def _setup_plan(plan_id, status, body_text, project_name)
  let dir = getenv("TASK_ORCH_STATE") + "/_plans/" + plan_id
  System.run_sync(["mkdir", "-p", dir])
  Trusted.write(dir + "/status", "2025-01-01T00:00:00\t" + status)
  Trusted.write(dir + "/body", body_text)
  if project_name != ""
    let proj_path = "/tmp/test-projects/" + project_name
    System.run_sync(["mkdir", "-p", proj_path])
    Trusted.write(dir + "/project_path", proj_path)
  end
end

def _plans_cleanup()
  let dir = getenv("TASK_ORCH_STATE") + "/_plans"
  if Trusted.exists(dir)
    System.run_sync(["rm", "-rf", dir])
  end
  System.run_sync(["rm", "-rf", "/tmp/test-projects"])
end

describe("PlansController", fn()
  describe("GET /plans", fn()
    before_each(fn()
      assert_test_db()
      Task.delete_all()
      Setting.delete_all()
      _plans_cleanup()
      as_guest()
    end)

    test("returns 200 when no plans dir exists", fn()
      let response = get("/plans")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "No unconverted plans found")
    end)

    test("returns 200 with empty state", fn()
      System.run_sync(["mkdir", "-p", getenv("TASK_ORCH_STATE") + "/_plans"])
      let response = get("/plans")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "No unconverted plans found")
    end)

    test("shows a done plan without a matching task", fn()
      _setup_plan("plan-1", "done", "# My test plan\n\nSome body text", "testproj")
      let response = get("/plans")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "My test plan")
      assert_contains(res_body(response), "plan-1")
      assert_contains(res_body(response), "Create task")
    end)

    test("hides a plan when a matching Task exists", fn()
      _setup_plan("plan-2", "done", "# Already done\n\nBody here", "testproj")
      Task.create({
        "_key":    "testproj--already-done",
        "project": "testproj",
        "slug":    "already-done",
        "title":   "Already done",
        "status":  "todo"
      })
      let response = get("/plans")
      assert_eq(res_status(response), 200)
      # The only plan present should be hidden → empty state
      assert_contains(res_body(response), "No unconverted plans found")
    end)

    test("skips in-progress plans", fn()
      _setup_plan("plan-3", "starting", "# Incomplete\n\nBody", "testproj")
      _setup_plan("plan-4", "planning", "# Also incomplete\n\nBody", "testproj")
      let response = get("/plans")
      assert_eq(res_status(response), 200)
      # Both plans have non-done status → empty state
      assert_contains(res_body(response), "No unconverted plans found")
    end)

    test("skips plans with missing body file", fn()
      let dir = getenv("TASK_ORCH_STATE") + "/_plans/plan-5"
      System.run_sync(["mkdir", "-p", dir])
      Trusted.write(dir + "/status", "2025-01-01T00:00:00\tdone")
      let response = get("/plans")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "No unconverted plans found")
    end)

    test("skips plans with unparseable status file gracefully", fn()
      let dir = getenv("TASK_ORCH_STATE") + "/_plans/plan-6"
      System.run_sync(["mkdir", "-p", dir])
      let response = get("/plans")
      assert_eq(res_status(response), 200)
    end)
  end)
end)
