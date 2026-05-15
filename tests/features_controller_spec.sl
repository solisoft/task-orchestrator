# FeaturesController and Feature model — covers CRUD operations and
# the generate-tasks pipeline.

describe("Feature model", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    Comment.delete_all()
  end)

  test("key_for composes project and slug", fn()
    assert_eq(Feature.key_for("myapp", "feat1"), "myapp--feat1")
  end)

  test("statuses returns all valid statuses", fn()
    let s = Feature.statuses()
    assert_eq(s.length(), 4)
    assert_eq(s[0], "draft")
    assert_eq(s[3], "done")
  end)

  test("validates required fields", fn()
    let f = Feature.create({})
    assert(f._errors != nil)
  end)

  test("validates status format", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test",
      "status":  "invalid-status"
    })
    assert(f._errors != nil)
  end)

  test("creates a feature with valid data", fn()
    let f = Feature.create({
      "_key":        "myapp--dark-mode",
      "project":     "myapp",
      "slug":        "dark-mode",
      "title":       "Dark mode support",
      "description": "Add dark mode toggle to settings",
      "status":      "draft"
    })
    assert(f._errors == nil)
    assert_eq(f.title, "Dark mode support")
    assert_eq(f.project, "myapp")
    assert_eq(f.status, "draft")
    assert_eq(f._key, "myapp--dark-mode")
  end)

  test("sets created_at when a feature is created", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "draft"
    })
    assert(f._errors == nil)
    assert_not_null(f.created_at)
    assert(f.created_at != "")
  end)

  test("format_date renders an ISO timestamp as a human-readable date", fn()
    assert_eq(format_date("2026-05-13T10:30:00Z"), "13 May 2026")
  end)

  test("format_date returns empty string for nil or empty input", fn()
    assert_eq(format_date(nil), "")
    assert_eq(format_date(""), "")
  end)

  test("format_date returns empty string for unparseable input", fn()
    assert_eq(format_date("not-a-date"), "")
  end)

  test("find_by_slug returns feature or nil", fn()
    Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "draft"
    })
    let f = Feature.find_by_slug("myapp", "feat1")
    assert_not_null(f)
    let missing = Feature.find_by_slug("myapp", "nonexistent")
    assert_null(missing)
  end)

  test("for_project returns features for a project", fn()
    Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Feature One",
      "status":  "draft"
    })
    Feature.create({
      "_key":    "myapp--feat2",
      "project": "myapp",
      "slug":    "feat2",
      "title":   "Feature Two",
      "status":  "ready"
    })
    Feature.create({
      "_key":    "other--feat3",
      "project": "other",
      "slug":    "feat3",
      "title":   "Other Feature",
      "status":  "draft"
    })
    let myapp_features = Feature.for_project("myapp")
    assert_eq(myapp_features.length(), 2)
    let other_features = Feature.for_project("other")
    assert_eq(other_features.length(), 1)
  end)

  test("tasks returns linked tasks", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "draft"
    })
    Task.create({
      "_key":         "myapp--task1",
      "project":      "myapp",
      "slug":         "task1",
      "title":        "A task",
      "status":       "todo",
      "feature_slug": "myapp--feat1",
      "author":       "test@example.com"
    })
    Task.create({
      "_key":         "myapp--task2",
      "project":      "myapp",
      "slug":         "task2",
      "title":        "Another task",
      "status":       "todo",
      "feature_slug": "myapp--feat1",
      "author":       "test@example.com"
    })
    let tasks = f.tasks()
    assert_eq(tasks.length(), 2)
  end)

  test("comments returns associated comments", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "draft"
    })
    Comment.create_comment("myapp--feat1", "user@test.com", "Nice feature!")
    Comment.create_comment("myapp--feat1", "user2@test.com", "I agree")
    let comments = f.comments()
    assert_eq(comments.length(), 2)
    assert_eq(comments[0].body, "Nice feature!")
    assert_eq(comments[1].body, "I agree")
  end)

  test("updates feature fields and saves", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Old Title",
      "status":  "draft"
    })
    f.title = "New Title"
    f.description = "Updated description"
    f.status = "ready"
    f.save()
    let reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.title, "New Title")
    assert_eq(reloaded.description, "Updated description")
    assert_eq(reloaded.status, "ready")
  end)

  test("delete removes the feature", fn()
    Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "To Delete",
      "status":  "draft"
    })
    let f = Feature.find_by_slug("myapp", "feat1")
    assert_not_null(f)
    f.delete()
    let deleted = Feature.find_by_slug("myapp", "feat1")
    assert_null(deleted)
  end)

  test("task has feature_slug and author fields", fn()
    let task = Task.create({
      "_key":         "myapp--task1",
      "project":      "myapp",
      "slug":         "task1",
      "title":        "A task linked to a feature",
      "status":       "todo",
      "feature_slug": "myapp--feat1",
      "author":       "user@example.com"
    })
    assert(task._errors == nil)
    assert_eq(task.feature_slug, "myapp--feat1")
    assert_eq(task.author, "user@example.com")
  end)

  test("recompute_status! flips to done when every linked task is done", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "in-progress"
    })
    Task.create({
      "_key":         "myapp--a",
      "project":      "myapp",
      "slug":         "a",
      "title":        "a",
      "status":       "done",
      "feature_slug": "myapp--feat1"
    })
    Task.create({
      "_key":         "myapp--b",
      "project":      "myapp",
      "slug":         "b",
      "title":        "b",
      "status":       "done",
      "feature_slug": "myapp--feat1"
    })
    assert(f.recompute_status!())
    let reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.status, "done")
  end)

  test("recompute_status! is a no-op when a linked task is still open", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "in-progress"
    })
    Task.create({
      "_key":         "myapp--a",
      "project":      "myapp",
      "slug":         "a",
      "title":        "a",
      "status":       "done",
      "feature_slug": "myapp--feat1"
    })
    Task.create({
      "_key":         "myapp--b",
      "project":      "myapp",
      "slug":         "b",
      "title":        "b",
      "status":       "review",
      "feature_slug": "myapp--feat1"
    })
    assert(not f.recompute_status!())
    let reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.status, "in-progress")
  end)

  test("recompute_status! ignores archived tasks", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "in-progress"
    })
    Task.create({
      "_key":         "myapp--a",
      "project":      "myapp",
      "slug":         "a",
      "title":        "a",
      "status":       "done",
      "feature_slug": "myapp--feat1"
    })
    Task.create({
      "_key":         "myapp--b",
      "project":      "myapp",
      "slug":         "b",
      "title":        "b",
      "status":       "archived",
      "feature_slug": "myapp--feat1"
    })
    assert(f.recompute_status!())
    let reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.status, "done")
  end)

  test("recompute_status! refuses to complete a feature with no done task", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "ready"
    })
    Task.create({
      "_key":         "myapp--a",
      "project":      "myapp",
      "slug":         "a",
      "title":        "a",
      "status":       "archived",
      "feature_slug": "myapp--feat1"
    })
    assert(not f.recompute_status!())
    let reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.status, "ready")
  end)

  test("recompute_status! does nothing for a feature already done", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "done"
    })
    assert(not f.recompute_status!())
  end)

  test("refresh_for_task auto-completes the parent feature", fn()
    Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "Test Feature",
      "status":  "in-progress"
    })
    let t = Task.create({
      "_key":         "myapp--solo",
      "project":      "myapp",
      "slug":         "solo",
      "title":        "solo",
      "status":       "done",
      "feature_slug": "myapp--feat1"
    })
    let refreshed = Feature.refresh_for_task(t)
    assert_not_null(refreshed)
    let reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.status, "done")
  end)

  test("refresh_for_task returns nil for a task with no feature_slug", fn()
    let t = Task.create({
      "_key":    "myapp--orphan",
      "project": "myapp",
      "slug":    "orphan",
      "title":   "orphan",
      "status":  "done"
    })
    assert_null(Feature.refresh_for_task(t))
  end)

  test("persists plan_model on the feature row", fn()
    let f = Feature.create({
      "_key":       "myapp--feat1",
      "project":    "myapp",
      "slug":       "feat1",
      "title":      "Test Feature",
      "status":     "draft",
      "plan_model": "claude-opus-4-7"
    })
    assert(f._errors == nil)
    let reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.plan_model, "claude-opus-4-7")
  end)

  describe("search", fn()
    before_each(fn()
      assert_test_db()
      Feature.delete_all()
      Feature.create({
        "_key":    "proj1--dark-mode",
        "project": "proj1",
        "slug":    "dark-mode",
        "title":   "Dark mode support",
        "description": "Add dark mode toggle across the app",
        "status":  "draft"
      })
      Feature.create({
        "_key":    "proj1--search-bar",
        "project": "proj1",
        "slug":    "search-bar",
        "title":   "Search bar component",
        "description": "Build a reusable search bar",
        "status":  "draft"
      })
      Feature.create({
        "_key":    "proj2--dark-theme",
        "project": "proj2",
        "slug":    "dark-theme",
        "title":   "Dark theme for dashboard",
        "description": "Implement dark mode on the dashboard page",
        "status":  "ready"
      })
    end)

    test("returns results matching title", fn()
      let result = Feature.search("", "dark", 0, 10)
      assert_eq(result["total"], 2)
      assert_eq(result["results"].length(), 2)
    end)

    test("returns results matching description", fn()
      let result = Feature.search("", "reusable", 0, 10)
      assert_eq(result["total"], 1)
      assert_eq(result["results"].length(), 1)
      assert_eq(result["results"][0].title, "Search bar component")
    end)

    test("scopes search to a project", fn()
      let result = Feature.search("proj1", "dark", 0, 10)
      assert_eq(result["total"], 1)
      assert_eq(result["results"].length(), 1)
      assert_eq(result["results"][0].title, "Dark mode support")
    end)

    test("returns empty array when nothing matches", fn()
      let result = Feature.search("", "nonexistent", 0, 10)
      assert_eq(result["total"], 0)
      assert_eq(result["results"].length(), 0)
    end)

    test("respects limit", fn()
      let result = Feature.search("", "", 0, 1)
      assert_eq(result["results"].length(), 1)
      assert_eq(result["total"], 3)
    end)

    test("respects offset", fn()
      let first = Feature.search("", "", 0, 1)
      let second = Feature.search("", "", 1, 1)
      assert_eq(first["results"].length(), 1)
      assert_eq(second["results"].length(), 1)
      # Ensure offset returns a different feature than the first page
      assert(first["results"][0]._key != second["results"][0]._key)
    end)

    test("returns all features when query is empty and no project scope", fn()
      let result = Feature.search("", "", 0, 100)
      assert_eq(result["total"], 3)
      assert_eq(result["results"].length(), 3)
    end)

    test("returns project-scoped features when query is empty", fn()
      let result = Feature.search("proj2", "", 0, 10)
      assert_eq(result["total"], 1)
      assert_eq(result["results"].length(), 1)
      assert_eq(result["results"][0].title, "Dark theme for dashboard")
    end)
  end)

  test("for_project returns features for the given project", fn()
    Feature.delete_all()
    Feature.create({ "_key": "p1--f1", "project": "p1", "slug": "f1", "title": "F1", "status": "draft" })
    Feature.create({ "_key": "p1--f2", "project": "p1", "slug": "f2", "title": "F2", "status": "draft" })
    Feature.create({ "_key": "p2--f3", "project": "p2", "slug": "f3", "title": "F3", "status": "draft" })
    let features = Feature.for_project("p1")
    assert_eq(features.length(), 2)
  end)

  test("for_project returns empty for unknown project", fn()
    Feature.delete_all()
    assert_eq(Feature.for_project("nonexistent").length(), 0)
  end)

  test("find_by_slug returns nil for unknown feature", fn()
    Feature.delete_all()
    assert_null(Feature.find_by_slug("proj", "no-such-feature"))
  end)

  test("Feature.tasks returns linked tasks", fn()
    Feature.delete_all()
    Task.delete_all()
    let f = Feature.create({ "_key": "proj--with-tasks", "project": "proj", "slug": "with-tasks", "title": "With tasks", "status": "draft" })
    Task.create({ "_key": "proj--t1", "project": "proj", "slug": "t1", "title": "T1", "status": "todo", "feature_slug": "proj--with-tasks" })
    Task.create({ "_key": "proj--t2", "project": "proj", "slug": "t2", "title": "T2", "status": "done", "feature_slug": "proj--with-tasks" })
    let tasks = f.tasks()
    assert_eq(tasks.length(), 2)
  end)

  test("Feature.comments returns linked comments", fn()
    Feature.delete_all()
    Comment.delete_all()
    let f = Feature.create({ "_key": "proj--with-comments", "project": "proj", "slug": "with-comments", "title": "With comments", "status": "draft" })
    Comment.create_comment("proj--with-comments", "user@test.com", "First!")
    Comment.create_comment("proj--with-comments", "user@test.com", "Second!")
    let comments = f.comments()
    assert_eq(comments.length(), 2)
  end)

  test("refresh_for_task returns nil for nil task", fn()
    assert_null(Feature.refresh_for_task(nil))
  end)

  test("recompute_status! returns false when already done", fn()
    Feature.delete_all()
    let f = Feature.create({ "_key": "proj--already-done", "project": "proj", "slug": "already-done", "title": "Done", "status": "done" })
    assert(not f.recompute_status!())
  end)

  test("recompute_status! returns false when only archived tasks exist", fn()
    Feature.delete_all()
    Task.delete_all()
    let f = Feature.create({ "_key": "proj--archived-only", "project": "proj", "slug": "archived-only", "title": "Archived only", "status": "in-progress" })
    Task.create({ "_key": "proj--arch", "project": "proj", "slug": "arch", "title": "Arch", "status": "archived", "feature_slug": "proj--archived-only" })
    assert(not f.recompute_status!())
  end)
end)
describe("Feature row author column", fn()
  # /features is auth-gated AND CSRF-checked, so driving it through
  # the test client requires solving both the dynamic Origin port and
  # the session cookie surface. The controller logic is a 3-liner
  # (`req["current_user"].email` into the `author` field); this model
  # check captures the storage shape and the show/edit/index views
  # read the same column.
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
  end)

  test("persists author when Feature.create receives one", fn()
    let f = Feature.create({
      "_key":    "myapp--by-author",
      "project": "myapp",
      "slug":    "by-author",
      "title":   "By author",
      "status":  "draft",
      "author":  "author@example.com"
    })
    assert(f._errors == nil)
    let reloaded = Feature.find_by_slug("myapp", "by-author")
    assert_eq(reloaded.author, "author@example.com")
  end)
end)

# Derive the test server's origin from a probe response's `url` field.
# `test_server_url()` reports the parent process's port and breaks in
# parallel-worker mode; the response url reflects the worker's actual
# port (set in the request helper via the thread-local override), so
# we can build an Origin header that matches the CSRF check's request
# authority regardless of which worker we're running on.
def _publish_origin_for_worker()
  let probe = get("/login")
  let url = probe["url"] ?? ""
  # Strip everything after the authority: "http://host:port" — split on the
  # first "/" past the "http://" prefix without using index_of's offset arg
  # (Soli's string API doesn't accept a starting offset).
  let prefix = "http://"
  if not url.starts_with(prefix)
    return url
  end
  let rest = url.substring(prefix.length(), url.length())
  let slash = rest.index_of("/")
  if slash > 0
    return prefix + rest.substring(0, slash)
  end
  return url
end

describe("FeaturesController#publish", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    User.delete_all()
    # /features is auth-gated — perform a real login so the auth
    # middleware finds a User and lets publish through to the action.
    User.register("publish-tester@example.com", "password123", "Publish Tester")
    login("publish-tester@example.com", "password123")
  end)

  test("seeds the combined task with feature.plan_model so the agent inherits the choice", fn()
    Feature.create({
      "_key":       "proj--brief",
      "project":    "proj",
      "slug":       "brief",
      "title":      "Brief with model",
      "status":     "ready",
      "plan_model": "claude-opus-4-7"
    })
    Task.create({
      "_key":         "proj--proposed-one",
      "project":      "proj",
      "slug":         "proposed-one",
      "title":        "Proposed one",
      "body_md":      "## Task 1\n\nDo a thing.",
      "status":       "proposed",
      "feature_slug": "proj--brief"
    })
    let response = post("/features/proj--brief/publish", {}, {
      "headers": { "Origin": _publish_origin_for_worker() }
    })
    assert_eq(res_status(response), 302)
    # The bundled parent task inherits feature.plan_model so the agent
    # run picks up the user's preferred model without a manual override.
    let parent = Task.find_by_slug("proj", "brief-with-model")
    assert_not_null(parent)
    assert_eq(parent.model, "claude-opus-4-7")
    assert_eq(parent.status, "todo")
  end)

  test("leaves the combined task model empty when the feature has none set", fn()
    Feature.create({
      "_key":    "proj--brief-no-model",
      "project": "proj",
      "slug":    "brief-no-model",
      "title":   "Brief no model",
      "status":  "ready"
    })
    Task.create({
      "_key":         "proj--proposed-x",
      "project":      "proj",
      "slug":         "proposed-x",
      "title":        "Proposed x",
      "body_md":      "## Task 1\n\nWork.",
      "status":       "proposed",
      "feature_slug": "proj--brief-no-model"
    })
    let response = post("/features/proj--brief-no-model/publish", {}, {
      "headers": { "Origin": _publish_origin_for_worker() }
    })
    assert_eq(res_status(response), 302)
    let parent = Task.find_by_slug("proj", "brief-no-model")
    assert_not_null(parent)
    # Empty/missing feature.plan_model falls through as "" so the agent
    # uses the global default at run-time.
    assert((parent.model ?? "") == "")
  end)
end)

describe("Plan model resolution", fn()
  before_each(fn()
    assert_test_db()
    Setting.delete_all()
    Feature.delete_all()
  end)

  test("default_plan_model returns the canonical default when nothing is set", fn()
    assert_eq(Plan.default_plan_model(), "claude-sonnet-4-6")
  end)

  test("default_plan_model reads the plan_model setting when set", fn()
    Setting.set("plan_model", "claude-opus-4-7")
    assert_eq(Plan.default_plan_model(), "claude-opus-4-7")
  end)

  test("resolve_plan_model prefers the form override over feature + setting", fn()
    Setting.set("plan_model", "claude-sonnet-4-6")
    let f = Feature.create({
      "_key":       "myapp--feat1",
      "project":    "myapp",
      "slug":       "feat1",
      "title":      "F",
      "status":     "draft",
      "plan_model": "claude-haiku-4-5-20251001"
    })
    let resolved = Plan.resolve_plan_model(f, { "plan_model": "claude-opus-4-7" })
    assert_eq(resolved, "claude-opus-4-7")
  end)

  test("resolve_plan_model falls back to feature.plan_model when form is empty", fn()
    Setting.set("plan_model", "claude-sonnet-4-6")
    let f = Feature.create({
      "_key":       "myapp--feat1",
      "project":    "myapp",
      "slug":       "feat1",
      "title":      "F",
      "status":     "draft",
      "plan_model": "claude-opus-4-7"
    })
    let resolved = Plan.resolve_plan_model(f, { "plan_model": "" })
    assert_eq(resolved, "claude-opus-4-7")
  end)

  test("resolve_plan_model falls back to the global setting when neither form nor feature has a value", fn()
    Setting.set("plan_model", "claude-opus-4-7")
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "F",
      "status":  "draft"
    })
    let resolved = Plan.resolve_plan_model(f, {})
    assert_eq(resolved, "claude-opus-4-7")
  end)

  test("resolve_plan_model falls back to the canonical default when nothing is set anywhere", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "F",
      "status":  "draft"
    })
    let resolved = Plan.resolve_plan_model(f, {})
    assert_eq(resolved, "claude-sonnet-4-6")
  end)

  test("resolve_plan_model rejects an unknown form model and falls back to the default", fn()
    let f = Feature.create({
      "_key":    "myapp--feat1",
      "project": "myapp",
      "slug":    "feat1",
      "title":   "F",
      "status":  "draft"
    })
    # Shell-injection attempt — must be scrubbed by `allow_plan_model`.
    let resolved = Plan.resolve_plan_model(f, { "plan_model": "evil; rm -rf /" })
    assert_eq(resolved, "claude-sonnet-4-6")
  end)

  test("resolve_plan_model accepts an opencode model id verbatim", fn()
    let resolved = Plan.resolve_plan_model(nil, { "plan_model": "deepseek/deepseek-chat" })
    assert_eq(resolved, "deepseek/deepseek-chat")
  end)

  test("resolve_plan_model stitches a variant onto an opencode id", fn()
    let resolved = Plan.resolve_plan_model(nil, {
      "plan_model":   "deepseek/deepseek-chat",
      "plan_variant": "high"
    })
    assert_eq(resolved, "deepseek/deepseek-chat:high")
  end)

  test("allow_plan_model accepts every Claude SDK id from the allowlist", fn()
    assert_eq(Plan.allow_plan_model("claude-opus-4-7"), "claude-opus-4-7")
    assert_eq(Plan.allow_plan_model("claude-sonnet-4-6"), "claude-sonnet-4-6")
    assert_eq(Plan.allow_plan_model("claude-haiku-4-5-20251001"), "claude-haiku-4-5-20251001")
  end)

  test("resolve_plan_model accepts a codex model id", fn()
    let resolved = Plan.resolve_plan_model(nil, { "plan_model": "codex/gpt-4o" })
    assert_eq(resolved, "codex/gpt-4o")
  end)

  test("resolve_plan_model accepts a codex model id with variant", fn()
    let resolved = Plan.resolve_plan_model(nil, {
      "plan_model": "codex/o3-mini",
      "plan_variant": "high"
    })
    assert_eq(resolved, "codex/o3-mini:high")
  end)
end)

describe("Feature model status transitions", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
  end)

  test("a feature with no tasks stays in its initial status", fn()
    let f = Feature.create({
      "_key": "proj--empty", "project": "proj", "slug": "empty",
      "title": "Empty", "status": "draft"
    })
    assert(not f.recompute_status!())
    let reloaded = Feature.find_by_slug("proj", "empty")
    assert_eq(reloaded.status, "draft")
  end)

  test("a feature with all tasks done becomes done", fn()
    let f = Feature.create({
      "_key": "proj--all-done", "project": "proj", "slug": "all-done",
      "title": "All Done", "status": "in-progress"
    })
    Task.create({
      "_key": "proj--t1", "project": "proj", "slug": "t1",
      "title": "T1", "status": "done", "feature_slug": "proj--all-done"
    })
    Task.create({
      "_key": "proj--t2", "project": "proj", "slug": "t2",
      "title": "T2", "status": "done", "feature_slug": "proj--all-done"
    })
    assert(f.recompute_status!())
    assert_eq(Feature.find_by_slug("proj", "all-done").status, "done")
  end)

  test("a feature with mixed status stays in-progress", fn()
    let f = Feature.create({
      "_key": "proj--mixed", "project": "proj", "slug": "mixed",
      "title": "Mixed", "status": "in-progress"
    })
    Task.create({
      "_key": "proj--m1", "project": "proj", "slug": "m1",
      "title": "M1", "status": "done", "feature_slug": "proj--mixed"
    })
    Task.create({
      "_key": "proj--m2", "project": "proj", "slug": "m2",
      "title": "M2", "status": "todo", "feature_slug": "proj--mixed"
    })
    assert(not f.recompute_status!())
    assert_eq(Feature.find_by_slug("proj", "mixed").status, "in-progress")
  end)
end)

describe("FeaturesController CRUD", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    User.delete_all()
    Setting.delete_all()
    User.register("crud@test.com", "password", "CRUD")
    login("crud@test.com", "password")
  end)

  test("POST /features creates a feature and redirects", fn()
    let response = post("/features", {
      "title": "New Feature", "project": "proj", "description": "desc", "status": "draft"
    }, { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
    let f = Feature.find_by_slug("proj", "new-feature")
    assert_not_null(f)
    assert_eq(f.title, "New Feature")
  end)

  test("POST /features returns 422 when project is missing", fn()
    let response = post("/features", { "title": "No Project" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 422)
  end)

  test("POST /features/:id/update updates the feature", fn()
    Feature.create({
      "_key": "proj--update-me", "project": "proj", "slug": "update-me",
      "title": "Original", "status": "draft"
    })
    let response = post("/features/proj--update-me/update", { "title": "Updated Title" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
    let f = Feature.find_by_slug("proj", "update-me")
    assert_not_null(f)
    assert_eq(f.title, "Updated Title")
  end)

  test("POST /features/:id/destroy deletes the feature", fn()
    Feature.create({
      "_key": "proj--delete-me", "project": "proj", "slug": "delete-me",
      "title": "Delete Me", "status": "draft"
    })
    let response = post("/features/proj--delete-me/destroy", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
    assert_null(Feature.find_by_slug("proj", "delete-me"))
  end)

  test("POST /features/:id/destroy returns 404 for unknown feature", fn()
    let response = post("/features/no-such-feature/destroy", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 404)
  end)

  test("POST /features/:id/tasks/:slug/remove removes proposed task", fn()
    Feature.create({
      "_key": "proj--remove-f", "project": "proj", "slug": "remove-f",
      "title": "Remove F", "status": "draft"
    })
    Task.create({
      "_key": "proj--remove-t", "project": "proj", "slug": "remove-t",
      "title": "Remove T", "status": "proposed", "feature_slug": "proj--remove-f"
    })
    let response = post("/features/proj--remove-f/tasks/remove-t/remove", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
    assert_null(Task.find_by_slug("proj", "remove-t"))
  end)

  test("POST /features/:id/tasks/:slug/remove returns 422 for non-proposed task", fn()
    Feature.create({
      "_key": "proj--remove-f2", "project": "proj", "slug": "remove-f2",
      "title": "Remove F2", "status": "draft"
    })
    Task.create({
      "_key": "proj--remove-t2", "project": "proj", "slug": "remove-t2",
      "title": "Remove T2", "status": "todo", "feature_slug": "proj--remove-f2"
    })
    let response = post("/features/proj--remove-f2/tasks/remove-t2/remove", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 422)
  end)

  test("POST /features/:id/tasks/:slug/remove returns 404 for unknown task", fn()
    Feature.create({
      "_key": "proj--remove-f3", "project": "proj", "slug": "remove-f3",
      "title": "Remove F3", "status": "draft"
    })
    let response = post("/features/proj--remove-f3/tasks/no-such-task/remove", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 404)
  end)
end)

describe("FeaturesController GET routes", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("get@test.com", "password", "GET User")
    login("get@test.com", "password")
  end)

  test("GET /features returns 200", fn()
    let response = get("/features")
    assert_eq(res_status(response), 200)
  end)

  test("GET /features header shows logged-in user, not Sign in", fn()
    let response = get("/features")
    let body = res_body(response)
    assert_eq(res_status(response), 200)
    # Header partial should render the user's avatar/logout, not the Sign in CTA
    assert(!body.contains(">Sign in<"))
    assert(body.contains("/logout"))
  end)

  test("GET /features/:id shows a feature", fn()
    Feature.create({
      "_key": "proj--show-me", "project": "proj", "slug": "show-me",
      "title": "Show Me", "status": "draft"
    })
    let response = get("/features/proj--show-me")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "Show Me")
  end)

  test("GET /features/:id returns 404 for unknown feature", fn()
    let response = get("/features/no-such-feature")
    assert_eq(res_status(response), 404)
  end)

  test("GET /features/new returns 200", fn()
    let response = get("/features/new")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "New Feature Brief")
  end)

  test("GET /features/:id/edit shows edit form", fn()
    Feature.create({
      "_key": "proj--edit-me", "project": "proj", "slug": "edit-me",
      "title": "Edit Me", "status": "draft"
    })
    let response = get("/features/proj--edit-me/edit")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "Edit Me")
  end)

  test("GET /features with HX-Request and project returns cards", fn()
    Feature.create({
      "_key": "proj--f1", "project": "proj", "slug": "f1",
      "title": "Feature 1", "status": "draft"
    })
    let response = get("/features?project=proj&per_page=10",
      { "headers": { "HX-Request": "true" } })
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "Feature 1")
  end)

  test("GET /features with ?q= searches features", fn()
    Feature.create({
      "_key": "proj--search-me", "project": "proj", "slug": "search-me",
      "title": "Search Target", "status": "draft"
    })
    Feature.create({
      "_key": "proj--other", "project": "proj", "slug": "other",
      "title": "Other Feature", "status": "draft"
    })
    let response = get("/features?q=Search")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "Search Target")
  end)

  test("POST /features/:id/cancel_plan cancels active plan", fn()
    let f = Feature.create({
      "_key": "proj--cancel-f", "project": "proj", "slug": "cancel-f",
      "title": "Cancel F", "status": "draft"
    })
    Plan.create({
      "_key": "plan--cancel", "project": "proj", "plan_id": "plan--cancel",
      "feature_slug": "proj--cancel-f", "status": "starting",
      "prompt": "Feature brief: Cancel F", "pid": nil, "tasks_imported": false
    })
    let response = post("/features/proj--cancel-f/cancel_plan", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
    let plan = Plan.find_by_plan_id("plan--cancel")
    assert_not_null(plan)
    assert(plan.status.starts_with("failed:"))
  end)

  test("POST /features/:id/publish redirects when no proposed tasks", fn()
    Feature.create({
      "_key": "proj--no-proposed", "project": "proj", "slug": "no-proposed",
      "title": "No Proposed", "status": "ready"
    })
    let response = post("/features/proj--no-proposed/publish", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
  end)

  test("POST /features/:id/refine_tasks returns 422 with empty refinement", fn()
    Feature.create({
      "_key": "proj--refine", "project": "proj", "slug": "refine",
      "title": "Refine", "status": "draft"
    })
    let response = post("/features/proj--refine/refine_tasks", { "refinement": "" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 422)
  end)
end)

describe("FeaturesController WS stream access control", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    User.delete_all()
  end)

  test("read_plan_state returns stream_token for a plan that has one", fn()
    # Plan._key IS the plan_id (set to "plan-NNN" by spawn_plan_agent).
    let plan = Plan.create({
      "_key":         "plan-token-test",
      "project":      "proj",
      "plan_id":      "plan-token-test",
      "status":       "running",
      "stream_token": "secret-token-abc"
    })
    let state = read_plan_state("plan-token-test")
    assert_eq(state["stream_token"], "secret-token-abc")
  end)

  test("read_plan_state returns empty stream_token for a plan without one", fn()
    let plan = Plan.create({
      "_key":    "plan-no-token",
      "project": "proj",
      "plan_id": "plan-no-token",
      "status":  "running"
    })
    let state = read_plan_state("plan-no-token")
    assert_eq(state["stream_token"], "")
  end)

  test("generate_tasks_log renders data-stream-token from the plan", fn()
    let f = Feature.create({
      "_key":    "proj--feat-log-token",
      "project": "proj",
      "slug":    "feat-log-token",
      "title":   "Log Token Feature",
      "status":  "ready"
    })
    # _key must match what spawn_plan_agent sets: just the plan_id.
    let plan = Plan.create({
      "_key":         "plan-log-token",
      "project":      "proj",
      "plan_id":      "plan-log-token",
      "status":       "running",
      "feature_slug": f._key,
      "stream_token": "visible-token-xyz"
    })
    User.register("test@example.com", "password123", "Test User")
    login("test@example.com", "password123")
    let response = get("/features/proj--feat-log-token/generate_tasks_log/plan-log-token", {}, {
      "headers": { "Origin": _publish_origin_for_worker() }
    })
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "data-stream-token=\"visible-token-xyz\"")
  end)
end)

describe("FeaturesController#update edge cases", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    User.delete_all()
    User.register("upd@test.com", "password", "Upd")
    login("upd@test.com", "password")
  end)

  test("POST /features/:id/update returns 404 for unknown feature", fn()
    let response = post("/features/no-such/update", { "title": "x" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 404)
  end)

  test("POST /features/:id/update returns 422 when title is empty", fn()
    Feature.create({
      "_key": "proj--blank-title", "project": "proj", "slug": "blank-title",
      "title": "Original", "status": "draft"
    })
    let response = post("/features/proj--blank-title/update", { "title": "" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 422)
  end)

  test("GET /features/:id/edit returns 404 for unknown feature", fn()
    let response = get("/features/no-such/edit")
    assert_eq(res_status(response), 404)
  end)
end)

describe("FeaturesController#generate_tasks 404 + 422", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    User.delete_all()
    User.register("gen@test.com", "password", "Gen")
    login("gen@test.com", "password")
  end)

  test("returns 404 for unknown feature", fn()
    let response = post("/features/no-such-feature/generate_tasks", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 404)
  end)

  test("returns 422 when the feature has no description", fn()
    Feature.create({
      "_key": "proj--no-desc", "project": "proj", "slug": "no-desc",
      "title": "No Desc", "status": "draft"
    })
    let response = post("/features/proj--no-desc/generate_tasks", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 422)
  end)
end)

describe("FeaturesController#regenerate_tasks + refine_tasks 404", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    User.delete_all()
    User.register("regen@test.com", "password", "Regen")
    login("regen@test.com", "password")
  end)

  test("regenerate_tasks returns 404 for unknown feature", fn()
    let response = post("/features/no-such/regenerate_tasks", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 404)
  end)

  test("refine_tasks returns 404 for unknown feature", fn()
    let response = post("/features/no-such/refine_tasks", { "refinement": "more" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 404)
  end)
end)

describe("FeaturesController#cancel_plan edges", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    User.delete_all()
    User.register("cancel@test.com", "password", "Cancel")
    login("cancel@test.com", "password")
  end)

  test("returns 404 for unknown feature", fn()
    let response = post("/features/no-such/cancel_plan", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 404)
  end)

  test("redirects without changes when no plan exists for the feature", fn()
    Feature.create({
      "_key": "proj--no-plan", "project": "proj", "slug": "no-plan",
      "title": "No Plan", "status": "draft"
    })
    let response = post("/features/proj--no-plan/cancel_plan", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
  end)

  test("leaves a done plan's status alone but stamps tasks_imported", fn()
    Feature.create({
      "_key": "proj--done-plan", "project": "proj", "slug": "done-plan",
      "title": "Done Plan", "status": "draft"
    })
    Plan.create({
      "_key": "plan-cancel-done", "project": "proj", "plan_id": "plan-cancel-done",
      "status": "done", "feature_slug": "proj--done-plan", "tasks_imported": false
    })
    let response = post("/features/proj--done-plan/cancel_plan", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
    let plan = Plan.find_by_plan_id("plan-cancel-done")
    assert_eq(plan.status, "done")
    assert(plan.tasks_imported == true)
  end)
end)

describe("FeaturesController#generate_tasks_log", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("log@test.com", "password", "Log")
    login("log@test.com", "password")
  end)

  test("returns 404 for unknown feature", fn()
    let response = get("/features/no-such/generate_tasks_log/plan-x")
    assert_eq(res_status(response), 404)
  end)

  test("renders streaming progress for a running plan", fn()
    Feature.create({
      "_key": "proj--polling", "project": "proj", "slug": "polling",
      "title": "Polling", "status": "ready"
    })
    Plan.create({
      "_key": "plan-poll", "project": "proj", "plan_id": "plan-poll",
      "status": "running", "feature_slug": "proj--polling",
      "pid": 1, "log": "doing work", "stream_token": "tk"
    })
    let response = get("/features/proj--polling/generate_tasks_log/plan-poll")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "generate-progress")
    assert_contains(body, "doing work")
  end)

  test("renders failed state when the plan has failed", fn()
    Feature.create({
      "_key": "proj--boom-f", "project": "proj", "slug": "boom-f",
      "title": "Boom", "status": "ready"
    })
    Plan.create({
      "_key": "plan-boom", "project": "proj", "plan_id": "plan-boom",
      "status": "failed:exit-1", "feature_slug": "proj--boom-f", "log": "broke"
    })
    let response = get("/features/proj--boom-f/generate_tasks_log/plan-boom")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "Plan failed")
  end)

  test("imports proposed tasks and signals reload when the plan is done", fn()
    Feature.create({
      "_key": "proj--done-import", "project": "proj", "slug": "done-import",
      "title": "Done Import", "description": "yes", "status": "ready"
    })
    Plan.create({
      "_key": "plan-done-import", "project": "proj", "plan_id": "plan-done-import",
      "status": "done", "feature_slug": "proj--done-import",
      "body": "## Task 1: First import\n\nDo this.\n\n## Task 2: Second import\n\nAnd this.",
      "tasks_imported": false
    })
    let response = get("/features/proj--done-import/generate_tasks_log/plan-done-import")
    assert_eq(res_status(response), 200)
    let proposed = Task.where({ "feature_slug": "proj--done-import", "status": "proposed" }).all()
    assert_eq(proposed.length(), 2)
    let plan = Plan.find_by_plan_id("plan-done-import")
    assert(plan.tasks_imported == true)
  end)

  test("renders single-select pending question form", fn()
    Feature.create({
      "_key": "proj--qs", "project": "proj", "slug": "qs",
      "title": "Q Single", "status": "ready"
    })
    Plan.create({
      "_key": "plan-q-single", "project": "proj", "plan_id": "plan-q-single",
      "status": "awaiting", "feature_slug": "proj--qs",
      "pending_question": {
        "id":   "qid-1",
        "tool": "AskUserQuestion",
        "input": { "questions": [{
          "question":    "Pick one?",
          "multiSelect": false,
          "options": [
            { "label": "Alpha", "description": "First" },
            { "label": "Beta",  "description": "Second" }
          ]
        }]}
      },
      "pid": 1
    })
    let response = get("/features/proj--qs/generate_tasks_log/plan-q-single")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "Pick one?")
    assert_contains(body, "Alpha")
    assert_contains(body, "Beta")
  end)

  test("renders multi-select pending question form", fn()
    Feature.create({
      "_key": "proj--qm", "project": "proj", "slug": "qm",
      "title": "Q Multi", "status": "ready"
    })
    Plan.create({
      "_key": "plan-q-multi", "project": "proj", "plan_id": "plan-q-multi",
      "status": "awaiting", "feature_slug": "proj--qm",
      "pending_question": {
        "id":   "qid-2",
        "tool": "AskUserQuestion",
        "input": { "questions": [{
          "question":    "Pick many?",
          "multiSelect": true,
          "options": [
            { "label": "Red",   "description": "" },
            { "label": "Green", "description": "" }
          ]
        }]}
      },
      "pid": 1
    })
    let response = get("/features/proj--qm/generate_tasks_log/plan-q-multi")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "Pick many?")
    assert_contains(body, "Submit selection")
  end)

  test("imports a single-section plan body via the fallback heading parser", fn()
    Feature.create({
      "_key": "proj--solo-import", "project": "proj", "slug": "solo-import",
      "title": "Solo", "description": "x", "status": "ready"
    })
    Plan.create({
      "_key": "plan-solo", "project": "proj", "plan_id": "plan-solo",
      "status": "done", "feature_slug": "proj--solo-import",
      "body": "# Just one heading\n\nbody content here", "tasks_imported": false
    })
    let response = get("/features/proj--solo-import/generate_tasks_log/plan-solo")
    assert_eq(res_status(response), 200)
    let proposed = Task.where({ "feature_slug": "proj--solo-import", "status": "proposed" }).all()
    assert_eq(proposed.length(), 1)
  end)
end)

describe("FeaturesController#plan_answer", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("ans@test.com", "password", "Ans")
    login("ans@test.com", "password")
  end)

  test("returns 404 for unknown feature", fn()
    let response = post("/features/no-such/plan-answer/plan-x",
      { "qid": "q", "value": "yes" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 404)
  end)

  test("returns 422 when qid is empty", fn()
    Feature.create({
      "_key": "proj--ans-empty", "project": "proj", "slug": "ans-empty",
      "title": "Ans Empty", "status": "ready"
    })
    let response = post("/features/proj--ans-empty/plan-answer/plan-x",
      { "qid": "", "value": "ok" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 422)
  end)

  test("returns 422 when value is empty", fn()
    Feature.create({
      "_key": "proj--ans-value-empty", "project": "proj", "slug": "ans-value-empty",
      "title": "Ans Value Empty", "status": "ready"
    })
    let response = post("/features/proj--ans-value-empty/plan-answer/plan-x",
      { "qid": "q", "value": "" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 422)
  end)

  test("writes the answer onto a running plan and renders progress", fn()
    Feature.create({
      "_key": "proj--ans-running", "project": "proj", "slug": "ans-running",
      "title": "Ans Running", "status": "ready"
    })
    Plan.create({
      "_key": "plan-ans-running", "project": "proj", "plan_id": "plan-ans-running",
      "status": "running", "feature_slug": "proj--ans-running",
      "pid": 1, "stream_token": "tk"
    })
    let response = post("/features/proj--ans-running/plan-answer/plan-ans-running",
      { "qid": "q1", "value": "yes" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 200)
    let plan = Plan.find_by_plan_id("plan-ans-running")
    assert_eq(plan.pending_question["id"], "q1")
    assert_eq(plan.pending_question["value"], "yes")
  end)

  test("imports tasks and redirects when the answer arrives after the plan finishes", fn()
    Feature.create({
      "_key": "proj--ans-done", "project": "proj", "slug": "ans-done",
      "title": "Ans Done", "status": "ready"
    })
    Plan.create({
      "_key": "plan-ans-done", "project": "proj", "plan_id": "plan-ans-done",
      "status": "done", "feature_slug": "proj--ans-done",
      "body": "## Task 1: Late\n\nAfter the fact.", "tasks_imported": false
    })
    let response = post("/features/proj--ans-done/plan-answer/plan-ans-done",
      { "qid": "q1", "value": "yes" },
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 200)
    let imported = Task.where({ "feature_slug": "proj--ans-done", "status": "proposed" }).all()
    assert_eq(imported.length(), 1)
  end)
end)

describe("FeaturesController#show wider state", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    Comment.delete_all()
    User.delete_all()
    User.register("show@test.com", "password", "Show")
    login("show@test.com", "password")
  end)

  test("splits tasks into proposed and linked buckets in the show page", fn()
    Feature.create({
      "_key": "proj--mix", "project": "proj", "slug": "mix",
      "title": "Mix", "description": "x", "status": "ready"
    })
    Task.create({
      "_key": "proj--mix-prop", "project": "proj", "slug": "mix-prop",
      "title": "Proposed One", "status": "proposed", "feature_slug": "proj--mix"
    })
    Task.create({
      "_key": "proj--mix-todo", "project": "proj", "slug": "mix-todo",
      "title": "Linked One", "status": "todo", "feature_slug": "proj--mix"
    })
    Comment.create_comment("proj--mix", "show@test.com", "Looks nice")
    let response = get("/features/proj--mix")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "Proposed One")
    assert_contains(body, "Linked One")
    assert_contains(body, "Looks nice")
  end)

  test("finalizes a done-but-unimported plan when the feature page is rendered", fn()
    Feature.create({
      "_key": "proj--finalize", "project": "proj", "slug": "finalize",
      "title": "Finalize Plan", "description": "yep", "status": "ready"
    })
    Plan.create({
      "_key": "plan-finalize", "project": "proj", "plan_id": "plan-finalize",
      "status": "done", "feature_slug": "proj--finalize",
      "body": "## Task 1: From plan\n\nDetails.", "tasks_imported": false
    })
    let response = get("/features/proj--finalize")
    assert_eq(res_status(response), 200)
    let plan = Plan.find_by_plan_id("plan-finalize")
    assert(plan.tasks_imported == true)
    let imported = Task.where({ "feature_slug": "proj--finalize", "status": "proposed" }).all()
    assert_eq(imported.length(), 1)
  end)

  test("finalizes a done plan matched by prompt prefix when feature_slug is unset", fn()
    Feature.create({
      "_key": "proj--prefix-match", "project": "proj", "slug": "prefix-match",
      "title": "Prefix Match", "description": "yes", "status": "ready"
    })
    # Older plans don't carry feature_slug — they match by the
    # "Feature brief: <title>" prompt prefix instead.
    Plan.create({
      "_key": "plan-prefix", "project": "proj", "plan_id": "plan-prefix",
      "status": "done", "prompt": "Feature brief: Prefix Match\n\nyes",
      "body":  "## Task 1: Prefix Imported\n\nbody.", "tasks_imported": false
    })
    let response = get("/features/proj--prefix-match")
    assert_eq(res_status(response), 200)
    let plan = Plan.find_by_plan_id("plan-prefix")
    assert(plan.tasks_imported == true)
  end)
end)

describe("FeaturesController#index htmx + project_param", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    User.delete_all()
    User.register("idx@test.com", "password", "Idx")
    login("idx@test.com", "password")
  end)

  test("returns project-scoped cards via the htmx load-more branch", fn()
    Feature.create({
      "_key": "proj--card-1", "project": "proj", "slug": "card-1",
      "title": "Card One", "status": "draft"
    })
    Feature.create({
      "_key": "proj--card-2", "project": "proj", "slug": "card-2",
      "title": "Card Two", "status": "draft"
    })
    let response = get("/features?project=proj&offset=0&per_page=1",
      { "headers": { "HX-Request": "true" } })
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert(body.contains("Card One") or body.contains("Card Two"))
  end)

  test("returns grouped htmx response when no project param is supplied", fn()
    Feature.create({
      "_key": "proj--group-1", "project": "proj", "slug": "group-1",
      "title": "Group Feature", "status": "draft"
    })
    let response = get("/features",
      { "headers": { "HX-Request": "true" } })
    assert_eq(res_status(response), 200)
  end)

  test("clamps negative offset to zero", fn()
    Feature.create({
      "_key": "proj--neg", "project": "proj", "slug": "neg",
      "title": "Neg", "status": "draft"
    })
    let response = get("/features?project=proj&offset=-5&per_page=1",
      { "headers": { "HX-Request": "true" } })
    assert_eq(res_status(response), 200)
  end)

  test("clamps zero per_page to default", fn()
    Feature.create({
      "_key": "proj--zero-pp", "project": "proj", "slug": "zero-pp",
      "title": "Zero PP", "status": "draft"
    })
    let response = get("/features?project=proj&offset=0&per_page=0",
      { "headers": { "HX-Request": "true" } })
    assert_eq(res_status(response), 200)
  end)
end)

describe("FeaturesController#new with project param", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    User.delete_all()
    User.register("new@test.com", "password", "New")
    login("new@test.com", "password")
  end)

  test("GET /features/new with ?project= renders without crashing on a missing project", fn()
    let response = get("/features/new?project=nonexistent")
    assert_eq(res_status(response), 200)
  end)
end)

describe("FeaturesController#create + update error paths", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    User.delete_all()
    User.register("err@test.com", "password", "Err")
    login("err@test.com", "password")
  end)

  test("POST /features stores plan_model when supplied via the form", fn()
    let response = post("/features", {
      "title":      "With Model",
      "project":    "projmodel",
      "status":     "draft",
      "plan_model": "claude-opus-4-7"
    }, { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
    let f = Feature.find_by_slug("projmodel", "with-model")
    assert_not_null(f)
    assert_eq(f.plan_model, "claude-opus-4-7")
  end)

  test("POST /features/:id/update accepts a plan_model field", fn()
    Feature.create({
      "_key": "proj--upd-model", "project": "proj", "slug": "upd-model",
      "title": "Upd Model", "status": "draft"
    })
    let response = post("/features/proj--upd-model/update", {
      "title": "Upd Model", "plan_model": "claude-haiku-4-5-20251001"
    }, { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
    let f = Feature.find_by_slug("proj", "upd-model")
    assert_eq(f.plan_model, "claude-haiku-4-5-20251001")
  end)
end)

describe("FeaturesController#publish with description", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("desc@test.com", "password", "Desc")
    login("desc@test.com", "password")
  end)

  test("renders the feature description as a header in the combined task body", fn()
    Feature.create({
      "_key": "proj--with-desc", "project": "proj", "slug": "with-desc",
      "title": "Featured", "description": "Why we want it.", "status": "ready"
    })
    Task.create({
      "_key": "proj--prop-desc-1", "project": "proj", "slug": "prop-desc-1",
      "title": "Build it", "body_md": "details", "status": "proposed",
      "feature_slug": "proj--with-desc"
    })
    let response = post("/features/proj--with-desc/publish", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 302)
    let parent = Task.find_by_slug("proj", "featured")
    assert_not_null(parent)
    # The combined body starts with the feature title + description block.
    assert_contains(parent.body_md, "# Featured")
    assert_contains(parent.body_md, "Why we want it.")
    assert_contains(parent.body_md, "## Task 1: Build it")
  end)
end)

describe("FeaturesController#generate_tasks_log idempotency + parser fallbacks", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("idem@test.com", "password", "Idem")
    login("idem@test.com", "password")
  end)

  test("re-polling a done + already-imported plan is a no-op (no duplicate tasks)", fn()
    Feature.create({
      "_key": "proj--idem", "project": "proj", "slug": "idem",
      "title": "Idem", "description": "x", "status": "ready"
    })
    Plan.create({
      "_key": "plan-idem", "project": "proj", "plan_id": "plan-idem",
      "status": "done", "feature_slug": "proj--idem",
      "body":  "## Task 1: Once\n\nonly.",
      "tasks_imported":      true,
      "imported_task_count": 1
    })
    Task.create({
      "_key": "proj--once", "project": "proj", "slug": "once",
      "title": "Once", "status": "proposed", "feature_slug": "proj--idem"
    })
    let response = get("/features/proj--idem/generate_tasks_log/plan-idem")
    assert_eq(res_status(response), 200)
    # Already-imported plan must not re-import: still exactly one task.
    let tasks = Task.where({ "feature_slug": "proj--idem", "status": "proposed" }).all()
    assert_eq(tasks.length(), 1)
  end)

  test("uses a level-2 heading as the fallback title when the body has no '## Task' marker", fn()
    Feature.create({
      "_key": "proj--h2", "project": "proj", "slug": "h2",
      "title": "H2 Fallback", "description": "x", "status": "draft"
    })
    Plan.create({
      "_key": "plan-h2", "project": "proj", "plan_id": "plan-h2",
      "status": "done", "feature_slug": "proj--h2",
      "body": "## Some subheading\n\nbody.", "tasks_imported": false
    })
    let response = get("/features/proj--h2/generate_tasks_log/plan-h2")
    assert_eq(res_status(response), 200)
    let proposed = Task.where({ "feature_slug": "proj--h2", "status": "proposed" }).all()
    assert_eq(proposed.length(), 1)
    assert_eq(proposed[0].title, "Some subheading")
    # A draft feature flips to "ready" once tasks are imported.
    let f = Feature.find_by_slug("proj", "h2")
    assert_eq(f.status, "ready")
  end)

  test("uses the first non-blank line as a fallback title when no heading is present", fn()
    Feature.create({
      "_key": "proj--noheading", "project": "proj", "slug": "noheading",
      "title": "No Heading", "description": "x", "status": "draft"
    })
    Plan.create({
      "_key": "plan-nh", "project": "proj", "plan_id": "plan-nh",
      "status": "done", "feature_slug": "proj--noheading",
      "body": "just one short paragraph", "tasks_imported": false
    })
    let response = get("/features/proj--noheading/generate_tasks_log/plan-nh")
    assert_eq(res_status(response), 200)
    let proposed = Task.where({ "feature_slug": "proj--noheading", "status": "proposed" }).all()
    assert_eq(proposed.length(), 1)
    assert_eq(proposed[0].title, "just one short paragraph")
  end)

  test("truncates an over-long first line in the fallback title", fn()
    Feature.create({
      "_key": "proj--long", "project": "proj", "slug": "long",
      "title": "Long Line", "description": "x", "status": "draft"
    })
    let long = "this is a deliberately very long single line that " +
               "should be truncated by the fallback title helper " +
               "because it exceeds sixty characters"
    Plan.create({
      "_key": "plan-long", "project": "proj", "plan_id": "plan-long",
      "status": "done", "feature_slug": "proj--long",
      "body": long, "tasks_imported": false
    })
    let response = get("/features/proj--long/generate_tasks_log/plan-long")
    assert_eq(res_status(response), 200)
    let proposed = Task.where({ "feature_slug": "proj--long", "status": "proposed" }).all()
    assert_eq(proposed.length(), 1)
    # Title is truncated with an ellipsis suffix.
    assert(proposed[0].title.ends_with("..."))
    assert(proposed[0].title.length() <= 65)
  end)

  test("renders option descriptions when the multi-select question carries them", fn()
    Feature.create({
      "_key": "proj--qm-desc", "project": "proj", "slug": "qm-desc",
      "title": "Q Multi w/ desc", "status": "ready"
    })
    Plan.create({
      "_key": "plan-qm-desc", "project": "proj", "plan_id": "plan-qm-desc",
      "status": "awaiting", "feature_slug": "proj--qm-desc",
      "pending_question": {
        "id":   "qm-desc",
        "tool": "AskUserQuestion",
        "input": { "questions": [{
          "question":    "Pick many with desc?",
          "multiSelect": true,
          "options": [
            { "label": "Apple", "description": "the fruit" },
            { "label": "Pear",  "description": "also a fruit" }
          ]
        }]}
      },
      "pid": 1
    })
    let response = get("/features/proj--qm-desc/generate_tasks_log/plan-qm-desc")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert_contains(body, "the fruit")
    assert_contains(body, "also a fruit")
  end)
end)

describe("FeaturesController#show with active plan", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("active@test.com", "password", "Active")
    login("active@test.com", "password")
  end)

  test("surfaces an in-flight plan tied by feature_slug as the active plan", fn()
    Feature.create({
      "_key": "proj--with-active", "project": "proj", "slug": "with-active",
      "title": "Has Active", "description": "x", "status": "ready"
    })
    # `pid: 1` (init) reliably reports alive on Linux test hosts, so
    # `effective_status` returns "running" instead of synthesizing a zombie.
    Plan.create({
      "_key": "plan-active", "project": "proj", "plan_id": "plan-active",
      "status": "running", "feature_slug": "proj--with-active",
      "pid": 1, "stream_token": "tk"
    })
    let response = get("/features/proj--with-active")
    assert_eq(res_status(response), 200)
  end)

  test("falls back to prompt-prefix matching when an in-flight plan lacks feature_slug", fn()
    Feature.create({
      "_key": "proj--prefix-active", "project": "proj", "slug": "prefix-active",
      "title": "Prefix Active", "description": "x", "status": "ready"
    })
    # No feature_slug — must be matched via the "Feature brief: <title>"
    # prompt prefix instead. Plan is still running so _finalize_done_plans
    # leaves it alone and _latest_plan_for / _active_plan_for traverse
    # the second (prompt-based) lookup loop.
    Plan.create({
      "_key": "plan-prefix-active", "project": "proj", "plan_id": "plan-prefix-active",
      "status": "running",
      "prompt": "Feature brief: Prefix Active\n\nx",
      "pid": 1, "stream_token": "tk"
    })
    let response = get("/features/proj--prefix-active")
    assert_eq(res_status(response), 200)
  end)
end)

describe("FeaturesController#generate_tasks_log slug collision", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("slug@test.com", "password", "Slug")
    login("slug@test.com", "password")
  end)

  test("import picks a numbered slug when the derived base collides", fn()
    Feature.create({
      "_key": "proj--collide-f", "project": "proj", "slug": "collide-f",
      "title": "Collide F", "description": "x", "status": "draft"
    })
    # Pre-seed a task whose slug matches what the parser would derive
    # from the plan section title — forces _unique_slug_local to bump.
    Task.create({
      "_key": "proj--collide-task", "project": "proj", "slug": "collide-task",
      "title": "Existing", "status": "todo"
    })
    Plan.create({
      "_key": "plan-collide", "project": "proj", "plan_id": "plan-collide",
      "status": "done", "feature_slug": "proj--collide-f",
      "body": "## Task 1: Collide task\n\nbody.", "tasks_imported": false
    })
    let response = get("/features/proj--collide-f/generate_tasks_log/plan-collide")
    assert_eq(res_status(response), 200)
    let proposed = Task.where({ "feature_slug": "proj--collide-f", "status": "proposed" }).all()
    assert_eq(proposed.length(), 1)
    # New task takes the "collide-task-2" slug to avoid colliding with the seeded one.
    assert_eq(proposed[0].slug, "collide-task-2")
  end)
end)

describe("FeaturesController#remove_task wrong feature link", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("link@test.com", "password", "Link")
    login("link@test.com", "password")
  end)

  test("POST /features/:id/tasks/:slug/remove returns 422 when the task belongs to a different feature", fn()
    Feature.create({
      "_key": "proj--alpha", "project": "proj", "slug": "alpha",
      "title": "Alpha", "status": "draft"
    })
    Feature.create({
      "_key": "proj--beta", "project": "proj", "slug": "beta",
      "title": "Beta", "status": "draft"
    })
    # Task is linked to alpha but the request targets beta.
    Task.create({
      "_key": "proj--alpha-task", "project": "proj", "slug": "alpha-task",
      "title": "Alpha Task", "status": "proposed", "feature_slug": "proj--alpha"
    })
    let response = post("/features/proj--beta/tasks/alpha-task/remove", {},
      { "headers": { "Origin": _publish_origin_for_worker() } })
    assert_eq(res_status(response), 422)
  end)
end)
