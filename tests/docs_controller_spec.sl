# Docs controller — covers the in-app Getting Started page reachable
# from the header (`📖 Docs` link). /docs is auth-gated; anonymous
# callers get a 302 to /login.
describe("DocsController", fn() {
  before_each(fn() {
    User.delete_all()
    User.register("docs@test.com", "password", "Docs User")
    login("docs@test.com", "password")
  })

  describe("GET /docs", fn() {

    # Soli's before_each doesn't cascade into nested describes — re-run
    # the login so any guest-leaning test above can't reset our session.
    before_each(fn() {
      User.delete_all()
      User.register("docs@test.com", "password", "Docs User")
      login("docs@test.com", "password")
    })

    test("returns 200", fn() {
      response = get("/docs")
      assert_eq(res_status(response), 200)
    })

    test("renders the Getting Started view", fn() {
      response = get("/docs")
      body = res_body(response)
      # Title from the docs/index view — confirms that template (not a
      # different view) was rendered.
      assert(body.contains("Getting Started"))
      assert(body.contains("Docs — Getting Started"))
    })

    test("covers every onboarding section", fn() {
      response = get("/docs")
      body = res_body(response)
      assert(body.contains("Overview"))
      assert(body.contains("Setup"))
      assert(body.contains("Daily use"))
      assert(body.contains("Configuration"))
      assert(body.contains("Failure mode"))
      assert(body.contains("State files"))
    })

    test("documents the dispatcher env vars", fn() {
      response = get("/docs")
      body = res_body(response)
      assert(body.contains("TASK_ORCH_ROOT"))
      assert(body.contains("TASK_ORCH_STATE"))
      assert(body.contains("TASK_ORCH_WORKTREES"))
    })

    test("links back to the workspace", fn() {
      response = get("/docs")
      body = res_body(response)
      assert(body.contains("href=\"/\""))
    })

    test("header shows the user avatar / logout for the signed-in user", fn() {
      response = get("/docs")
      body = res_body(response)
      assert_eq(res_status(response), 200)
      assert(!body.contains(">Sign in<"))
      assert(body.contains("/logout"))
    })
  })

  describe("anonymous access", fn() {

    # Outer before_each logs us in; this nested block runs after that, so
    # we must reset to a guest session before the redirect assertion.
    before_each(fn() { as_guest() })

    test("redirects /docs to /login for anonymous callers", fn() {
      response = get("/docs")
      assert_eq(res_status(response), 302)
      assert_contains(res_header(response, "Location") ?? "", "/login")
    })
  })
})
