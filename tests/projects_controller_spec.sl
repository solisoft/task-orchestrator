# Projects routes (`/projects`, `/projects/:name`) live behind the
# authenticate middleware. Each nested describe must re-establish the
# session in its own before_each — Soli's before_each does not cascade
# into nested describes.
fn _proj_login_test_user
  User.delete_all()
  User.register("proj@test.com", "password", "Proj Tester")
  login("proj@test.com", "password")
end

fn _proj_reset_state
  assert_test_db()
  Task.delete_all()
  Setting.delete_all()
  Version.delete_all()
  _proj_login_test_user()
end

# CSRF guard rejects cookie-bearing POSTs without Origin/Referer; probe
# /login to learn the dynamic test-server host (same as _tq_origin in
# tasks_controller_spec) and thread it through every POST.
fn _proj_origin
  probe = get("/login")
  url = probe["url"] ?? ""
  prefix = "http://"
  return url if !url.starts_with(prefix)
  rest = url.substring(prefix.length(), url.length())
  slash = rest.index_of("/")
  return prefix + rest.substring(0, slash) if slash > 0
  url
end

fn _proj_post(path, body)
  pst = post
  return pst(path, body, {"headers": {"Origin": _proj_origin()}})
end

describe("ProjectsController", fn() {
  describe("GET /projects", fn() {
    before_each(fn() { _proj_reset_state() })

    test("returns 200 and renders heading", fn() {
      response = get("/projects")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Projects")
    })

    test("lists each project on disk", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_alpha/tasks/todo", root + "/proj_alpha/.git"
      ])
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_beta/tasks/todo", root + "/proj_beta/.git"
      ])
      response = get("/projects")
      assert_contains(res_body(response), "proj_alpha")
      assert_contains(res_body(response), "proj_beta")
    })

    test("renders cycles shortcut link for each project", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_cycles/tasks/todo", root + "/proj_cycles/.git"
      ])
      response = get("/projects")
      assert_contains(res_body(response), "/projects/proj_cycles?tab=cycles")
    })

    test("redirects to /login when no session is set", fn() {
      as_guest()
      response = get("/projects")
      assert_eq(res_status(response), 302)
      assert_contains(res_header(response, "Location") ?? "", "/login")
    })
  })

  describe("GET /projects/:name", fn() {
    before_each(fn() { _proj_reset_state() })

    test("returns 404 for unknown project", fn() {
      response = get("/projects/nonexistent_project_xyz")
      assert_eq(res_status(response), 404)
    })

    test("returns 200 for project that exists on disk", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_show/tasks/todo", root + "/proj_show/.git"
      ])
      response = get("/projects/proj_show")
      assert_eq(res_status(response), 200)
    })

    test("renders the project name in the page", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/my_test_proj/tasks/todo", root + "/my_test_proj/.git"
      ])
      response = get("/projects/my_test_proj")
      assert_contains(res_body(response), "my_test_proj")
    })

    test("defaults to the Build tab", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_kanban/tasks/todo", root + "/proj_kanban/.git"
      ])
      response = get("/projects/proj_kanban")
      assert_contains(res_body(response), "Build")
      assert_contains(res_body(response), "Swimlanes")
    })

    test("flat fallback still shows the kanban columns", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_kanban2/tasks/todo", root + "/proj_kanban2/.git"
      ])
      response = get("/projects/proj_kanban2?tab=build&view=flat")
      assert_contains(res_body(response), "todo")
    })

    test("redirects to /login when no session is set", fn() {
      as_guest()
      response = get("/projects/whatever")
      assert_eq(res_status(response), 302)
      assert_contains(res_header(response, "Location") ?? "", "/login")
    })
  })

  describe("tab parameter", fn() {
    before_each(fn() { _proj_reset_state() })

    test("renders with archived tab when ?tab=archived", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_tab/tasks/todo", root + "/proj_tab/.git"
      ])
      response = get("/projects/proj_tab?tab=archived")
      assert_eq(res_status(response), 200)
    })

    test("legacy ?tab=board redirects to Build (alias)", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_aliasboard/tasks/todo", root + "/proj_aliasboard/.git"
      ])
      response = get("/projects/proj_aliasboard?tab=board")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Build")
    })

    test("legacy ?tab=roadmap renders Cycles (alias)", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_aliasroad/tasks/todo", root + "/proj_aliasroad/.git"
      ])
      response = get("/projects/proj_aliasroad?tab=roadmap")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Cycles")
    })

    test("?tab=shape renders draft features", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_shape/tasks/todo", root + "/proj_shape/.git"
      ])
      Feature.delete_all()
      Feature.create({
        "project": "proj_shape",
        "slug": "idea-a",
        "title": "Idea A",
        "status": "draft"
      }, {"key": "proj_shape--idea-a"})
      response = get("/projects/proj_shape?tab=shape")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Idea A")
      assert_contains(res_body(response), "Promote to bet")
    })

    test(
      "?tab=bet renders ready features with cycle picker",
      fn() {
        root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
        System.run_sync([
          "mkdir",
          "-p",
          root + "/proj_bet/tasks/todo", root + "/proj_bet/.git"
        ])
        Feature.delete_all()
        Version.delete_all()
        Feature.create({
          "project": "proj_bet",
          "slug": "brief-r",
          "title": "Brief R",
          "status": "ready"
        }, {"key": "proj_bet--brief-r"})
        Version.create({
          "project": "proj_bet",
          "name": "C1",
          "status": "active"
        })
        response = get("/projects/proj_bet?tab=bet")
        assert_eq(res_status(response), 200)
        assert_contains(res_body(response), "Brief R")
        assert_contains(res_body(response), "Generate tasks")
      }
    )

    test(
      "?tab=build renders feature swimlanes by default",
      fn() {
        root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
        System.run_sync([
          "mkdir",
          "-p",
          root + "/proj_build/tasks/todo", root + "/proj_build/.git"
        ])
        Feature.delete_all()
        Task.delete_all()
        Feature.create({
          "project": "proj_build",
          "slug": "feat-ip",
          "title": "Feature IP",
          "status": "in-progress"
        }, {"key": "proj_build--feat-ip"})
        Task.create({
          "project": "proj_build",
          "slug": "task-ip",
          "title": "Task IP",
          "status": "todo",
          "feature_slug": "proj_build--feat-ip"
        }, {"key": "proj_build--task-ip"})
        response = get("/projects/proj_build?tab=build")
        assert_eq(res_status(response), 200)
        assert_contains(res_body(response), "Feature IP")
        assert_contains(res_body(response), "Task IP")
      }
    )

    test(
      "?tab=build&view=flat falls back to the legacy board partial",
      fn() {
        root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
        System.run_sync([
          "mkdir",
          "-p",
          root + "/proj_flat/tasks/todo", root + "/proj_flat/.git"
        ])
        response = get("/projects/proj_flat?tab=build&view=flat")
        assert_eq(res_status(response), 200)
        # The flat board renders the per-status kanban columns nav (e.g. "todo")
        assert_contains(res_body(response), "id=\"board\"")
      }
    )

    test(
      "?tab=ship renders shipped features with their PR links",
      fn() {
        root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
        System.run_sync([
          "mkdir",
          "-p",
          root + "/proj_ship/tasks/todo", root + "/proj_ship/.git"
        ])
        Feature.delete_all()
        Task.delete_all()
        Feature.create({
          "project": "proj_ship",
          "slug": "feat-s",
          "title": "Feature Ship",
          "status": "in-progress"
        }, {"key": "proj_ship--feat-s"})
        Task.create({
          "project": "proj_ship",
          "slug": "task-r",
          "title": "Task Review",
          "status": "review",
          "feature_slug": "proj_ship--feat-s",
          "pr_url": "https://github.com/acme/repo/pull/42"
        }, {"key": "proj_ship--task-r"})
        response = get("/projects/proj_ship?tab=ship")
        assert_eq(res_status(response), 200)
        assert_contains(res_body(response), "Feature Ship")
        assert_contains(res_body(response), "github.com/acme/repo/pull/42")
      }
    )

    test("?tab=features (legacy) aliases to Build", fn() {
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_alias_feats/tasks/todo", root + "/proj_alias_feats/.git"
      ])
      response = get("/projects/proj_alias_feats?tab=features")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Build")
    })
  })

  describe("POST /projects/:name/settings", fn() {
    before_each(fn() {
      _proj_reset_state()
      root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
      System.run_sync([
        "mkdir",
        "-p",
        root + "/proj_settings/tasks/todo", root + "/proj_settings/.git"
      ])
    })

    test("persists per-project webhook secrets", fn() {
      response = _proj_post("/projects/proj_settings/settings", {
        "github_webhook_secret": "gh-secret-1",
        "gitlab_webhook_secret": "gl-secret-1"
      })
      assert_eq(res_status(response), 302)
      assert_eq(Setting.get("github_webhook_secret:proj_settings"), "gh-secret-1")
      assert_eq(Setting.get("gitlab_webhook_secret:proj_settings"), "gl-secret-1")
    })

    test("empty field clears the per-project secret (global fallback)", fn() {
      Setting.set("github_webhook_secret:proj_settings", "old-secret")
      response = _proj_post("/projects/proj_settings/settings", {
        "github_webhook_secret": "",
        "gitlab_webhook_secret": ""
      })
      assert_eq(res_status(response), 302)
      assert_null(Setting.get("github_webhook_secret:proj_settings"))
    })

    test("returns 404 for unknown project", fn() {
      response = _proj_post("/projects/nonexistent_project_xyz/settings", {
        "github_webhook_secret": "x"
      })
      assert_eq(res_status(response), 404)
    })

    test("redirects to /login when no session is set", fn() {
      as_guest()
      response = _proj_post("/projects/proj_settings/settings", {})
      assert_eq(res_status(response), 302)
      assert_contains(res_header(response, "Location") ?? "", "/login")
    })

    test("settings modal renders on the project page", fn() {
      Setting.set("github_webhook_secret:proj_settings", "modal-secret")
      response = get("/projects/proj_settings")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "project-settings-modal")
      assert_contains(res_body(response), "modal-secret")
    })
  })
})
