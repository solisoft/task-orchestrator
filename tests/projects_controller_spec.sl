describe("ProjectsController", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    Version.delete_all()
    as_guest()
  end)

  describe("GET /projects", fn()
    test("returns 200 and renders heading", fn()
      let response = get("/projects")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Projects")
    end)

    test("lists each project on disk", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_alpha/tasks/todo"])
      System.run_sync(["mkdir", "-p", root + "/proj_beta/tasks/todo"])
      let response = get("/projects")
      assert_contains(res_body(response), "proj_alpha")
      assert_contains(res_body(response), "proj_beta")
    end)

    test("renders roadmap shortcut link for each project", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_roadmap/tasks/todo"])
      let response = get("/projects")
      assert_contains(res_body(response), "/projects/proj_roadmap?tab=roadmap")
    end)
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

    test("renders the Features tab with the project's features and cycle picker", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_feats/tasks/todo"])
      Feature.delete_all()
      Feature.create({
        "_key": "proj_feats--brief-one", "project": "proj_feats",
        "slug": "brief-one", "title": "Brief One", "status": "draft"
      })
      let v = Version.create({
        "project": "proj_feats", "name": "Cycle Q3", "status": "active"
      })
      let response = get("/projects/proj_feats?tab=features")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Brief One")
      assert_contains(res_body(response), "Cycle Q3")
      assert_contains(res_body(response), "/features/proj_feats--brief-one/assign-cycle")
    end)
  end)
end)