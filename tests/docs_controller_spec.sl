# Docs controller — covers the in-app Getting Started page reachable
# from the home header (`📖 Docs` link).

describe("DocsController", fn() {
  before_each(fn() {
    as_guest();
  });

  describe("GET /docs", fn() {
    # Soli's before_each doesn't cascade into nested describes — re-assert
    # guest so the test above this block can't leak its login into the
    # next "header shows Sign in" assertion.
    before_each(fn() { as_guest(); });

    test("returns 200", fn() {
      let response = get("/docs");
      assert_eq(res_status(response), 200);
    });

    test("renders the Getting Started view", fn() {
      let response = get("/docs");
      let body = res_body(response);
      # Title from the docs/index view — confirms that template (not a
      # different view) was rendered.
      assert(body.contains("Getting Started"));
      assert(body.contains("Docs — Getting Started"));
    });

    test("covers every onboarding section", fn() {
      let response = get("/docs");
      let body = res_body(response);
      assert(body.contains("Overview"));
      assert(body.contains("Setup"));
      assert(body.contains("Daily use"));
      assert(body.contains("Configuration"));
      assert(body.contains("Failure mode"));
      assert(body.contains("State files"));
    });

    test("documents the dispatcher env vars", fn() {
      let response = get("/docs");
      let body = res_body(response);
      assert(body.contains("TASK_ORCH_ROOT"));
      assert(body.contains("TASK_ORCH_STATE"));
      assert(body.contains("TASK_ORCH_WORKTREES"));
    });

    test("links back to the project kanban", fn() {
      let response = get("/docs");
      let body = res_body(response);
      assert(body.contains("href=\"/\""));
    });

    test("header shows Sign in for guests", fn() {
      let response = get("/docs");
      let body = res_body(response);
      assert_eq(res_status(response), 200);
      assert(body.contains(">Sign in<"));
    });

    test("header shows user avatar when logged in", fn() {
      User.delete_all();
      User.register("docs@test.com", "password", "Docs User");
      login("docs@test.com", "password");
      let response = get("/docs");
      let body = res_body(response);
      assert_eq(res_status(response), 200);
      assert(!body.contains(">Sign in<"));
      assert(body.contains("/logout"));
    });
  });

  describe("GET / (anonymous landing)", fn() {
    # Outer before_each does not cascade into nested describes in Soli —
    # re-assert guest so a logged-in test above doesn't leak its session
    # into this one (would route us to the Workspace inbox instead).
    before_each(fn() { as_guest(); });

    test("links to the docs page", fn() {
      let response = get("/");
      let body = res_body(response);
      assert(body.contains("href=\"/docs\""));
      assert(body.contains("Docs"));
    });
  });
});
