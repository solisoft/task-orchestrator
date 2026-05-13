describe("ProjectsController", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    as_guest()
  end)

  describe("GET /projects/:name", fn()
    test("returns 404 for unknown project", fn()
      let response = get("/projects/nonexistent_project_xyz")
      assert_eq(res_status(response), 404)
    end)

    test("returns 200 for project that exists on disk", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_show/tasks/todo"])
      let response = get("/projects/proj_show")
      assert_eq(res_status(response), 200)
    end)

    test("renders the project name in the page", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/my_test_proj/tasks/todo"])
      let response = get("/projects/my_test_proj")
      assert_contains(res_body(response), "my_test_proj")
    end)

    test("renders kanban columns", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_kanban/tasks/todo"])
      let response = get("/projects/proj_kanban")
      assert_contains(res_body(response), "todo")
    end)
  end)

  describe("tab parameter", fn()
    test("renders with archived tab when ?tab=archived", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_tab/tasks/todo"])
      let response = get("/projects/proj_tab?tab=archived")
      assert_eq(res_status(response), 200)
    end)
  end)
end)