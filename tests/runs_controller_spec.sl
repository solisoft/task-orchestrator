# Run routes live behind the authenticate middleware. Each nested
# describe needs its own before_each since Soli's before_each does not
# cascade into nested describes.
fn _runs_login_test_user
  User.delete_all()
  User.register("runs@test.com", "password", "Runs Tester")
  login("runs@test.com", "password")
end

fn _runs_reset_state
  assert_test_db()
  Task.delete_all()
  _runs_login_test_user()
end

# Soli's CSRF guard rejects cookie-bearing POSTs without an Origin /
# Referer header. Probe /login to discover the dynamic test-server host
# so we can attach an Origin to each authenticated POST.
fn _runs_origin
  probe = get("/login")
  url = probe["url"] ?? ""
  prefix = "http://"
  return url if !url.starts_with(prefix)
  rest = url.substring(prefix.length(), url.length())
  slash = rest.index_of("/")
  return prefix + rest.substring(0, slash) if slash > 0
  url
end

fn _runs_post(path, body)
  pst = post
  return pst(path, body, {"headers": {"Origin": _runs_origin()}})
end

describe("RunsController", fn() {
  describe("GET /projects/:name/tasks/:slug/run", fn() {
    before_each(fn() { _runs_reset_state() })

    test("returns 404 for unknown project", fn() {
      response = get("/projects/nonexistent/tasks/some-task/run")
      assert_eq(res_status(response), 404)
    })

    test("returns 404 for unknown task", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_run_test/tasks/todo"
      ])
      response = get("/projects/proj_run_test/tasks/nonexistent/run")
      assert_eq(res_status(response), 404)
    })

    test("redirects to the task page (run now renders inline)", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_run_ok/tasks/todo"
      ])
      Task.create({
        "_key": "proj_run_ok--task-run",
        "project": "proj_run_ok",
        "slug": "task-run",
        "title": "Task Run",
        "status": "todo"
      })
      response = get("/projects/proj_run_ok/tasks/task-run/run")
      assert_eq(res_status(response), 302)
      assert_eq(res_header(response, "Location"), "/projects/proj_run_ok/tasks/task-run")
    })

    test("redirects to /login when no session is set", fn() {
      as_guest()
      response = get("/projects/anything/tasks/whatever/run")
      assert_eq(res_status(response), 302)
      assert_contains(res_header(response, "Location") ?? "", "/login")
    })
  })

  describe("GET /projects/:name/tasks/:slug/run/log", fn() {
    before_each(fn() { _runs_reset_state() })

    test("returns 404 for unknown project", fn() {
      response = get("/projects/nonexistent/tasks/some-task/run/log")
      assert_eq(res_status(response), 404)
    })

    test("returns 404 for unknown task", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_log_test/tasks/todo"
      ])
      response = get("/projects/proj_log_test/tasks/nonexistent/run/log")
      assert_eq(res_status(response), 404)
    })

    test("returns 200 for valid project and task", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_log_ok/tasks/todo"
      ])
      Task.create({
        "_key": "proj_log_ok--task-log",
        "project": "proj_log_ok",
        "slug": "task-log",
        "title": "Task Log",
        "status": "todo"
      })
      response = get("/projects/proj_log_ok/tasks/task-log/run/log")
      assert_eq(res_status(response), 200)
    })
  })

  describe("POST /projects/:name/tasks/:slug/run/resume", fn() {
    before_each(fn() { _runs_reset_state() })

    test("returns 422 for non-resumable task", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_resume/tasks/todo"
      ])
      Task.create({
        "_key": "proj_resume--resume-me",
        "project": "proj_resume",
        "slug": "resume-me",
        "title": "Resume me",
        "status": "done"
      })
      response = _runs_post("/projects/proj_resume/tasks/resume-me/run/resume", {})
      assert_eq(res_status(response), 422)
      assert_contains(res_body(response), "not in a resumable state")
    })
  })
})
