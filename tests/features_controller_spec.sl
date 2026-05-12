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
end)
