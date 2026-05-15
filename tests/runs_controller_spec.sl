describe("RunsController", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    as_guest()
  end)

  describe("GET /projects/:name/tasks/:slug/run", fn()
    test("returns 404 for unknown project", fn()
      let response = get("/projects/nonexistent/tasks/some-task/run")
      assert_eq(res_status(response), 404)
    end)

    test("returns 404 for unknown task", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_run_test/tasks/todo"])
      let response = get("/projects/proj_run_test/tasks/nonexistent/run")
      assert_eq(res_status(response), 404)
    end)

    test("returns 200 for valid project and task", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_run_ok/tasks/todo"])
      Task.create({
        "_key":    "proj_run_ok--task-run",
        "project": "proj_run_ok",
        "slug":    "task-run",
        "title":   "Task Run",
        "status":  "todo"
      })
      let response = get("/projects/proj_run_ok/tasks/task-run/run")
      assert_eq(res_status(response), 200)
    end)
  end)

  describe("GET /projects/:name/tasks/:slug/run/log", fn()
    test("returns 404 for unknown project", fn()
      let response = get("/projects/nonexistent/tasks/some-task/run/log")
      assert_eq(res_status(response), 404)
    end)

    test("returns 404 for unknown task", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_log_test/tasks/todo"])
      let response = get("/projects/proj_log_test/tasks/nonexistent/run/log")
      assert_eq(res_status(response), 404)
    end)

    test("returns 200 for valid project and task", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_log_ok/tasks/todo"])
      Task.create({
        "_key":    "proj_log_ok--task-log",
        "project": "proj_log_ok",
        "slug":    "task-log",
        "title":   "Task Log",
        "status":  "todo"
      })
      let response = get("/projects/proj_log_ok/tasks/task-log/run/log")
      assert_eq(res_status(response), 200)
    end)
  end)

  describe("POST /projects/:name/tasks/:slug/run/resume", fn()
    test("returns 422 for non-resumable task", fn()
      let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync(["mkdir", "-p", root + "/proj_resume/tasks/todo"])
      Task.create({
        "_key":    "proj_resume--resume-me",
        "project": "proj_resume",
        "slug":    "resume-me",
        "title":   "Resume me",
        "status":  "done"
      })
      let response = post("/projects/proj_resume/tasks/resume-me/run/resume", {})
      assert_eq(res_status(response), 422)
      assert_contains(res_body(response), "not in a resumable state")
    end)
  end)
end)