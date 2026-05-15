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
