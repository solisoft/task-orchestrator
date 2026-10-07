# FeaturesController and Feature model — covers CRUD operations and
# the generate-tasks pipeline.
describe("Feature model", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    Comment.delete_all()
  })

  test("key_for composes project and slug", fn() { assert_eq(Feature.key_for("myapp", "feat1"), "myapp--feat1") })

  describe("Feature#stage", fn() {
    test("draft brief with no tasks is in shape", fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "idea",
        "title": "Idea",
        "status": "draft"
      }, {"key": "myapp--idea"})
      assert_eq(f.stage({}), "shape")
    })

    test(
      "ready brief with no tasks is on the betting table",
      fn() {
        f = Feature.create({
          "project": "myapp",
          "slug": "ready1",
          "title": "Ready",
          "status": "ready"
        }, {"key": "myapp--ready1"})
        assert_eq(f.stage({}), "bet")
      }
    )

    test(
      "feature with todo/queued/inprogress tasks moves to build",
      fn() {
        f = Feature.create({
          "project": "myapp",
          "slug": "build1",
          "title": "Build",
          "status": "ready"
        }, {"key": "myapp--build1"})
        assert_eq(f.stage({"todo": 1}), "build")
        assert_eq(f.stage({"queued": 2}), "build")
        assert_eq(f.stage({"inprogress": 1}), "build")
        assert_eq(f.stage({"failed": 1}), "build")
      }
    )

    test("feature with tasks in review moves to ship", fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "ship1",
        "title": "Ship",
        "status": "in-progress"
      }, {"key": "myapp--ship1"})
      assert_eq(f.stage({"review": 1}), "ship")
      assert_eq(f.stage({"done": 1}), "ship")
      assert_eq(f.stage({"review": 1, "todo": 3}), "ship")
    })

    test("done feature is always ship", fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "done1",
        "title": "Done",
        "status": "done"
      }, {"key": "myapp--done1"})
      assert_eq(f.stage({}), "ship")
      assert_eq(f.stage({"todo": 99}), "ship")
    })

    test(
      "in-progress feature with no live tasks still reports build",
      fn() {
        f = Feature.create({
          "project": "myapp",
          "slug": "ip1",
          "title": "InP",
          "status": "in-progress"
        }, {"key": "myapp--ip1"})
        assert_eq(f.stage({}), "build")
      }
    )

    test(
      "stage with no arg counts the feature's own tasks",
      fn() {
        Task.delete_all()
        f = Feature.create({
          "project": "myapp",
          "slug": "auto1",
          "title": "Auto",
          "status": "ready"
        }, {"key": "myapp--auto1"})
        Task.create({
          "project": "myapp",
          "slug": "at1",
          "title": "T1",
          "status": "todo",
          "feature_slug": "myapp--auto1"
        }, {"key": "myapp--at1"})
        assert_eq(f.stage(), "build")
      }
    )
  })

  test("statuses returns all valid statuses", fn() {
    s = Feature.statuses()
    assert_eq(s.length(), 4)
    assert_eq(s[0], "draft")
    assert_eq(s[3], "done")
  })

  test("validates required fields", fn() {
    f = Feature.create({})
    assert(f._errors.present?)
  })

  test("validates status format", fn() {
    f = Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "Test",
      "status": "invalid-status"
    }, {"key": "myapp--feat1"})
    assert(f._errors.present?)
  })

  test("creates a feature with valid data", fn() {
    f = Feature.create({
      "project": "myapp",
      "slug": "dark-mode",
      "title": "Dark mode support",
      "description": "Add dark mode toggle to settings",
      "status": "draft"
    }, {"key": "myapp--dark-mode"})
    assert(f._errors.nil?)
    assert_eq(f.title, "Dark mode support")
    assert_eq(f.project, "myapp")
    assert_eq(f.status, "draft")
    assert_eq(f._key, "myapp--dark-mode")
  })

  test("sets created_at when a feature is created", fn() {
    f = Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "Test Feature",
      "status": "draft"
    }, {"key": "myapp--feat1"})
    assert(f._errors.nil?)
    assert_not_null(f.created_at)
    assert(f.created_at != "")
  })

  test(
    "format_date renders an ISO timestamp as a human-readable date",
    fn() { assert_eq(format_date("2026-05-13T10:30:00Z"), "13 May 2026") }
  )

  test(
    "format_date returns empty string for nil or empty input",
    fn() {
      assert_eq(format_date(nil), "")
      assert_eq(format_date(""), "")
    }
  )

  test("format_date returns empty string for unparseable input", fn() { assert_eq(format_date("not-a-date"), "") })

  test("find_by_slug returns feature or nil", fn() {
    Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "Test Feature",
      "status": "draft"
    }, {"key": "myapp--feat1"})
    f = Feature.find_by_slug("myapp", "feat1")
    assert_not_null(f)
    missing = Feature.find_by_slug("myapp", "nonexistent")
    assert_null(missing)
  })

  test("for_project returns features for a project", fn() {
    Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "Feature One",
      "status": "draft"
    }, {"key": "myapp--feat1"})
    Feature.create({
      "project": "myapp",
      "slug": "feat2",
      "title": "Feature Two",
      "status": "ready"
    }, {"key": "myapp--feat2"})
    Feature.create({
      "project": "other",
      "slug": "feat3",
      "title": "Other Feature",
      "status": "draft"
    }, {"key": "other--feat3"})
    myapp_features = Feature.for_project("myapp")
    assert_eq(myapp_features.length(), 2)
    other_features = Feature.for_project("other")
    assert_eq(other_features.length(), 1)
  })

  test("tasks returns linked tasks", fn() {
    f = Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "Test Feature",
      "status": "draft"
    }, {"key": "myapp--feat1"})
    Task.create({
      "project": "myapp",
      "slug": "task1",
      "title": "A task",
      "status": "todo",
      "feature_slug": "myapp--feat1",
      "author": "test@example.com"
    }, {"key": "myapp--task1"})
    Task.create({
      "project": "myapp",
      "slug": "task2",
      "title": "Another task",
      "status": "todo",
      "feature_slug": "myapp--feat1",
      "author": "test@example.com"
    }, {"key": "myapp--task2"})
    tasks = f.tasks()
    assert_eq(tasks.length(), 2)
  })

  test("comments returns associated comments", fn() {
    f = Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "Test Feature",
      "status": "draft"
    }, {"key": "myapp--feat1"})
    Comment.create_comment("myapp--feat1", "user@test.com", "Nice feature!")
    Comment.create_comment("myapp--feat1", "user2@test.com", "I agree")
    comments = f.comments()
    assert_eq(comments.length(), 2)
    assert_eq(comments[0].body, "Nice feature!")
    assert_eq(comments[1].body, "I agree")
  })

  test("updates feature fields and saves", fn() {
    f = Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "Old Title",
      "status": "draft"
    }, {"key": "myapp--feat1"})
    f.title = "New Title"
    f.description = "Updated description"
    f.status = "ready"
    f.save()
    reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.title, "New Title")
    assert_eq(reloaded.description, "Updated description")
    assert_eq(reloaded.status, "ready")
  })

  test("delete removes the feature", fn() {
    Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "To Delete",
      "status": "draft"
    }, {"key": "myapp--feat1"})
    f = Feature.find_by_slug("myapp", "feat1")
    assert_not_null(f)
    f.delete()
    deleted = Feature.find_by_slug("myapp", "feat1")
    assert_null(deleted)
  })

  test("task has feature_slug and author fields", fn() {
    task = Task.create({
      "project": "myapp",
      "slug": "task1",
      "title": "A task linked to a feature",
      "status": "todo",
      "feature_slug": "myapp--feat1",
      "author": "user@example.com"
    }, {"key": "myapp--task1"})
    assert(task._errors.nil?)
    assert_eq(task.feature_slug, "myapp--feat1")
    assert_eq(task.author, "user@example.com")
  })

  test(
    "recompute_status! flips to done when every linked task is done",
    fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "Test Feature",
        "status": "in-progress"
      }, {"key": "myapp--feat1"})
      Task.create({
        "project": "myapp",
        "slug": "a",
        "title": "a",
        "status": "done",
        "feature_slug": "myapp--feat1"
      }, {"key": "myapp--a"})
      Task.create({
        "project": "myapp",
        "slug": "b",
        "title": "b",
        "status": "done",
        "feature_slug": "myapp--feat1"
      }, {"key": "myapp--b"})
      assert(f.recompute_status!())
      reloaded = Feature.find_by_slug("myapp", "feat1")
      assert_eq(reloaded.status, "done")
    }
  )

  test(
    "recompute_status! is a no-op when a linked task is still open",
    fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "Test Feature",
        "status": "in-progress"
      }, {"key": "myapp--feat1"})
      Task.create({
        "project": "myapp",
        "slug": "a",
        "title": "a",
        "status": "done",
        "feature_slug": "myapp--feat1"
      }, {"key": "myapp--a"})
      Task.create({
        "project": "myapp",
        "slug": "b",
        "title": "b",
        "status": "review",
        "feature_slug": "myapp--feat1"
      }, {"key": "myapp--b"})
      assert(!f.recompute_status!())
      reloaded = Feature.find_by_slug("myapp", "feat1")
      assert_eq(reloaded.status, "in-progress")
    }
  )

  test("recompute_status! ignores archived tasks", fn() {
    f = Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "Test Feature",
      "status": "in-progress"
    }, {"key": "myapp--feat1"})
    Task.create({
      "project": "myapp",
      "slug": "a",
      "title": "a",
      "status": "done",
      "feature_slug": "myapp--feat1"
    }, {"key": "myapp--a"})
    Task.create({
      "project": "myapp",
      "slug": "b",
      "title": "b",
      "status": "archived",
      "feature_slug": "myapp--feat1"
    }, {"key": "myapp--b"})
    assert(f.recompute_status!())
    reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.status, "done")
  })

  test(
    "recompute_status! refuses to complete a feature with no done task",
    fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "Test Feature",
        "status": "ready"
      }, {"key": "myapp--feat1"})
      Task.create({
        "project": "myapp",
        "slug": "a",
        "title": "a",
        "status": "archived",
        "feature_slug": "myapp--feat1"
      }, {"key": "myapp--a"})
      assert(!f.recompute_status!())
      reloaded = Feature.find_by_slug("myapp", "feat1")
      assert_eq(reloaded.status, "ready")
    }
  )

  test(
    "recompute_status! does nothing for a feature already done",
    fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "Test Feature",
        "status": "done"
      }, {"key": "myapp--feat1"})
      assert(!f.recompute_status!())
    }
  )

  test(
    "refresh_for_task auto-completes the parent feature",
    fn() {
      Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "Test Feature",
        "status": "in-progress"
      }, {"key": "myapp--feat1"})
      t = Task.create({
        "project": "myapp",
        "slug": "solo",
        "title": "solo",
        "status": "done",
        "feature_slug": "myapp--feat1"
      }, {"key": "myapp--solo"})
      refreshed = Feature.refresh_for_task(t)
      assert_not_null(refreshed)
      reloaded = Feature.find_by_slug("myapp", "feat1")
      assert_eq(reloaded.status, "done")
    }
  )

  test(
    "refresh_for_task returns nil for a task with no feature_slug",
    fn() {
      t = Task.create({
        "project": "myapp",
        "slug": "orphan",
        "title": "orphan",
        "status": "done"
      }, {"key": "myapp--orphan"})
      assert_null(Feature.refresh_for_task(t))
    }
  )

  test("persists plan_model on the feature row", fn() {
    f = Feature.create({
      "project": "myapp",
      "slug": "feat1",
      "title": "Test Feature",
      "status": "draft",
      "plan_model": "claude-opus-4-7"
    }, {"key": "myapp--feat1"})
    assert(f._errors.nil?)
    reloaded = Feature.find_by_slug("myapp", "feat1")
    assert_eq(reloaded.plan_model, "claude-opus-4-7")
  })

  describe("search", fn() {
    before_each(fn() {
      assert_test_db()
      Feature.delete_all()
      Feature.create({
        "project": "proj1",
        "slug": "dark-mode",
        "title": "Dark mode support",
        "description": "Add dark mode toggle across the app",
        "status": "draft"
      }, {"key": "proj1--dark-mode"})
      Feature.create({
        "project": "proj1",
        "slug": "search-bar",
        "title": "Search bar component",
        "description": "Build a reusable search bar",
        "status": "draft"
      }, {"key": "proj1--search-bar"})
      Feature.create({
        "project": "proj2",
        "slug": "dark-theme",
        "title": "Dark theme for dashboard",
        "description": "Implement dark mode on the dashboard page",
        "status": "ready"
      }, {"key": "proj2--dark-theme"})
    })

    test("returns results matching title", fn() {
      result = Feature.search("", "dark", 0, 10)
      assert_eq(result["total"], 2)
      assert_eq(result["results"].length(), 2)
    })

    test("returns results matching description", fn() {
      result = Feature.search("", "reusable", 0, 10)
      assert_eq(result["total"], 1)
      assert_eq(result["results"].length(), 1)
      assert_eq(result["results"][0].title, "Search bar component")
    })

    test("scopes search to a project", fn() {
      result = Feature.search("proj1", "dark", 0, 10)
      assert_eq(result["total"], 1)
      assert_eq(result["results"].length(), 1)
      assert_eq(result["results"][0].title, "Dark mode support")
    })

    test("returns empty array when nothing matches", fn() {
      result = Feature.search("", "nonexistent", 0, 10)
      assert_eq(result["total"], 0)
      assert_eq(result["results"].length(), 0)
    })

    test("respects limit", fn() {
      result = Feature.search("", "", 0, 1)
      assert_eq(result["results"].length(), 1)
      assert_eq(result["total"], 3)
    })

    test("respects offset", fn() {
      first = Feature.search("", "", 0, 1)
      second = Feature.search("", "", 1, 1)
      assert_eq(first["results"].length(), 1)
      assert_eq(second["results"].length(), 1)
      # Ensure offset returns a different feature than the first page
      assert(first["results"][0]._key != second["results"][0]._key)
    })

    test(
      "returns all features when query is empty and no project scope",
      fn() {
        result = Feature.search("", "", 0, 100)
        assert_eq(result["total"], 3)
        assert_eq(result["results"].length(), 3)
      }
    )

    test(
      "returns project-scoped features when query is empty",
      fn() {
        result = Feature.search("proj2", "", 0, 10)
        assert_eq(result["total"], 1)
        assert_eq(result["results"].length(), 1)
        assert_eq(result["results"][0].title, "Dark theme for dashboard")
      }
    )
  })

  test(
    "for_project returns features for the given project",
    fn() {
      Feature.delete_all()
      Feature.create({
        "project": "p1",
        "slug": "f1",
        "title": "F1",
        "status": "draft"
      }, {"key": "p1--f1"})
      Feature.create({
        "project": "p1",
        "slug": "f2",
        "title": "F2",
        "status": "draft"
      }, {"key": "p1--f2"})
      Feature.create({
        "project": "p2",
        "slug": "f3",
        "title": "F3",
        "status": "draft"
      }, {"key": "p2--f3"})
      features = Feature.for_project("p1")
      assert_eq(features.length(), 2)
    }
  )

  test("for_project returns empty for unknown project", fn() {
    Feature.delete_all()
    assert_eq(Feature.for_project("nonexistent").length(), 0)
  })

  test("find_by_slug returns nil for unknown feature", fn() {
    Feature.delete_all()
    assert_null(Feature.find_by_slug("proj", "no-such-feature"))
  })

  test("Feature.tasks returns linked tasks", fn() {
    Feature.delete_all()
    Task.delete_all()
    f = Feature.create({
      "project": "proj",
      "slug": "with-tasks",
      "title": "With tasks",
      "status": "draft"
    }, {"key": "proj--with-tasks"})
    Task.create({
      "project": "proj",
      "slug": "t1",
      "title": "T1",
      "status": "todo",
      "feature_slug": "proj--with-tasks"
    }, {"key": "proj--t1"})
    Task.create({
      "project": "proj",
      "slug": "t2",
      "title": "T2",
      "status": "done",
      "feature_slug": "proj--with-tasks"
    }, {"key": "proj--t2"})
    tasks = f.tasks()
    assert_eq(tasks.length(), 2)
  })

  test("Feature.comments returns linked comments", fn() {
    Feature.delete_all()
    Comment.delete_all()
    f = Feature.create({
      "project": "proj",
      "slug": "with-comments",
      "title": "With comments",
      "status": "draft"
    }, {"key": "proj--with-comments"})
    Comment.create_comment("proj--with-comments", "user@test.com", "First!")
    Comment.create_comment("proj--with-comments", "user@test.com", "Second!")
    comments = f.comments()
    assert_eq(comments.length(), 2)
  })

  test("refresh_for_task returns nil for nil task", fn() { assert_null(Feature.refresh_for_task(nil)) })

  test(
    "recompute_status! returns false when already done",
    fn() {
      Feature.delete_all()
      f = Feature.create({
        "project": "proj",
        "slug": "already-done",
        "title": "Done",
        "status": "done"
      }, {"key": "proj--already-done"})
      assert(!f.recompute_status!())
    }
  )

  test(
    "recompute_status! returns false when only archived tasks exist",
    fn() {
      Feature.delete_all()
      Task.delete_all()
      f = Feature.create({
        "project": "proj",
        "slug": "archived-only",
        "title": "Archived only",
        "status": "in-progress"
      }, {"key": "proj--archived-only"})
      Task.create({
        "project": "proj",
        "slug": "arch",
        "title": "Arch",
        "status": "archived",
        "feature_slug": "proj--archived-only"
      }, {"key": "proj--arch"})
      assert(!f.recompute_status!())
    }
  )
})
describe("Feature row author column", fn() {

  # /features is auth-gated AND CSRF-checked, so driving it through
  # the test client requires solving both the dynamic Origin port and
  # the session cookie surface. The controller logic is a 3-liner
  # (`req["current_user"].email` into the `author` field); this model
  # check captures the storage shape and the show/edit/index views
  # read the same column.
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
  })

  test(
    "persists author when Feature.create receives one",
    fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "by-author",
        "title": "By author",
        "status": "draft",
        "author": "author@example.com"
      }, {"key": "myapp--by-author"})
      assert(f._errors.nil?)
      reloaded = Feature.find_by_slug("myapp", "by-author")
      assert_eq(reloaded.author, "author@example.com")
    }
  )
})

# Derive the test server's origin from a probe response's `url` field.
# `test_server_url()` reports the parent process's port and breaks in
# parallel-worker mode; the response url reflects the worker's actual
# port (set in the request helper via the thread-local override), so
# we can build an Origin header that matches the CSRF check's request
# authority regardless of which worker we're running on.
fn _publish_origin_for_worker
  probe = get("/login")
  url = probe["url"] ?? ""
  # Strip everything after the authority: "http://host:port" — split on the
  # first "/" past the "http://" prefix without using index_of's offset arg
  # (Soli's string API doesn't accept a starting offset).
  prefix = "http://"
  return url if !url.starts_with(prefix)
  rest = url.substring(prefix.length(), url.length())
  slash = rest.index_of("/")
  return prefix + rest.substring(0, slash) if slash > 0
  return url
end

describe("FeaturesController#publish", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    User.delete_all()
    # /features is auth-gated — perform a real login so the auth
    # middleware finds a User and lets publish through to the action.
    User.register("publish-tester@example.com", "password123", "Publish Tester")
    login("publish-tester@example.com", "password123")
  })

  test(
    "seeds the combined task with feature.plan_model so the agent inherits the choice",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "brief",
        "title": "Brief with model",
        "status": "ready",
        "plan_model": "claude-opus-4-7"
      }, {"key": "proj--brief"})
      Task.create({
        "project": "proj",
        "slug": "proposed-one",
        "title": "Proposed one",
        "body_md": "## Task 1\n\nDo a thing.",
        "status": "proposed",
        "feature_slug": "proj--brief"
      }, {"key": "proj--proposed-one"})
      response = post("/features/proj--brief/publish", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
      assert_eq(res_status(response), 302)
      # The bundled parent task inherits feature.plan_model so the agent
      # run picks up the user's preferred model without a manual override.
      parent = Task.find_by_slug("proj", "brief-with-model")
      assert_not_null(parent)
      assert_eq(parent.model, "claude-opus-4-7")
      assert_eq(parent.status, "todo")
    }
  )

  test(
    "leaves the combined task model empty when the feature has none set",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "brief-no-model",
        "title": "Brief no model",
        "status": "ready"
      }, {"key": "proj--brief-no-model"})
      Task.create({
        "project": "proj",
        "slug": "proposed-x",
        "title": "Proposed x",
        "body_md": "## Task 1\n\nWork.",
        "status": "proposed",
        "feature_slug": "proj--brief-no-model"
      }, {"key": "proj--proposed-x"})
      response = post(
        "/features/proj--brief-no-model/publish",
        {},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 302)
      parent = Task.find_by_slug("proj", "brief-no-model")
      assert_not_null(parent)
      # Empty/missing feature.plan_model falls through as "" so the agent
      # uses the global default at run-time.
      assert((parent.model ?? "") == "")
    }
  )
})

describe("Plan model resolution", fn() {
  before_each(fn() {
    assert_test_db()
    Setting.delete_all()
    Feature.delete_all()
  })

  test(
    "default_plan_model returns the canonical default when nothing is set",
    fn() { assert_eq(Plan.default_plan_model(), "claude-sonnet-4-6") }
  )

  test(
    "default_plan_model reads the plan_model setting when set",
    fn() {
      Setting.set("plan_model", "claude-opus-4-7")
      assert_eq(Plan.default_plan_model(), "claude-opus-4-7")
    }
  )

  test(
    "resolve_plan_model prefers the form override over feature + setting",
    fn() {
      Setting.set("plan_model", "claude-sonnet-4-6")
      f = Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "F",
        "status": "draft",
        "plan_model": "claude-haiku-4-5-20251001"
      }, {"key": "myapp--feat1"})
      resolved = Plan.resolve_plan_model(f, {"plan_model": "claude-opus-4-7"})
      assert_eq(resolved, "claude-opus-4-7")
    }
  )

  test(
    "resolve_plan_model falls back to feature.plan_model when form is empty",
    fn() {
      Setting.set("plan_model", "claude-sonnet-4-6")
      f = Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "F",
        "status": "draft",
        "plan_model": "claude-opus-4-7"
      }, {"key": "myapp--feat1"})
      resolved = Plan.resolve_plan_model(f, {"plan_model": ""})
      assert_eq(resolved, "claude-opus-4-7")
    }
  )

  test(
    "resolve_plan_model falls back to the global setting when neither form nor feature has a value",
    fn() {
      Setting.set("plan_model", "claude-opus-4-7")
      f = Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "F",
        "status": "draft"
      }, {"key": "myapp--feat1"})
      resolved = Plan.resolve_plan_model(f, {})
      assert_eq(resolved, "claude-opus-4-7")
    }
  )

  test(
    "resolve_plan_model falls back to the canonical default when nothing is set anywhere",
    fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "F",
        "status": "draft"
      }, {"key": "myapp--feat1"})
      resolved = Plan.resolve_plan_model(f, {})
      assert_eq(resolved, "claude-sonnet-4-6")
    }
  )

  test(
    "resolve_plan_model rejects an unknown form model and falls back to the default",
    fn() {
      f = Feature.create({
        "project": "myapp",
        "slug": "feat1",
        "title": "F",
        "status": "draft"
      }, {"key": "myapp--feat1"})

      # Shell-injection attempt — must be scrubbed by `allow_plan_model`.
      resolved = Plan.resolve_plan_model(f, {"plan_model": "evil; rm -rf /"})
      assert_eq(resolved, "claude-sonnet-4-6")
    }
  )

  test(
    "resolve_plan_model accepts an opencode model id verbatim",
    fn() {
      resolved = Plan.resolve_plan_model(nil, {"plan_model": "deepseek/deepseek-chat"})
      assert_eq(resolved, "deepseek/deepseek-chat")
    }
  )

  test(
    "resolve_plan_model stitches a variant onto an opencode id",
    fn() {
      resolved = Plan.resolve_plan_model(
        nil,
        {"plan_model": "deepseek/deepseek-chat", "plan_variant": "high"}
      )
      assert_eq(resolved, "deepseek/deepseek-chat:high")
    }
  )

  test(
    "allow_plan_model accepts every Claude SDK id from the allowlist",
    fn() {
      assert_eq(Plan.allow_plan_model("claude-opus-4-7"), "claude-opus-4-7")
      assert_eq(Plan.allow_plan_model("claude-sonnet-4-6"), "claude-sonnet-4-6")
      assert_eq(Plan.allow_plan_model("claude-haiku-4-5-20251001"), "claude-haiku-4-5-20251001")
    }
  )

  test("resolve_plan_model accepts a codex model id", fn() {
    resolved = Plan.resolve_plan_model(nil, {"plan_model": "codex/gpt-4o"})
    assert_eq(resolved, "codex/gpt-4o")
  })

  test(
    "resolve_plan_model accepts a codex model id with variant",
    fn() {
      resolved = Plan.resolve_plan_model(
        nil,
        {"plan_model": "codex/o3-mini", "plan_variant": "high"}
      )
      assert_eq(resolved, "codex/o3-mini:high")
    }
  )
})

describe("Feature model status transitions", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
  })

  test(
    "a feature with no tasks stays in its initial status",
    fn() {
      f = Feature.create({
        "project": "proj",
        "slug": "empty",
        "title": "Empty",
        "status": "draft"
      }, {"key": "proj--empty"})
      assert(!f.recompute_status!())
      reloaded = Feature.find_by_slug("proj", "empty")
      assert_eq(reloaded.status, "draft")
    }
  )

  test("a feature with all tasks done becomes done", fn() {
    f = Feature.create({
      "project": "proj",
      "slug": "all-done",
      "title": "All Done",
      "status": "in-progress"
    }, {"key": "proj--all-done"})
    Task.create({
      "project": "proj",
      "slug": "t1",
      "title": "T1",
      "status": "done",
      "feature_slug": "proj--all-done"
    }, {"key": "proj--t1"})
    Task.create({
      "project": "proj",
      "slug": "t2",
      "title": "T2",
      "status": "done",
      "feature_slug": "proj--all-done"
    }, {"key": "proj--t2"})
    assert(f.recompute_status!())
    assert_eq(Feature.find_by_slug("proj", "all-done").status, "done")
  })

  test("a feature with mixed status stays in-progress", fn() {
    f = Feature.create({
      "project": "proj",
      "slug": "mixed",
      "title": "Mixed",
      "status": "in-progress"
    }, {"key": "proj--mixed"})
    Task.create({
      "project": "proj",
      "slug": "m1",
      "title": "M1",
      "status": "done",
      "feature_slug": "proj--mixed"
    }, {"key": "proj--m1"})
    Task.create({
      "project": "proj",
      "slug": "m2",
      "title": "M2",
      "status": "todo",
      "feature_slug": "proj--mixed"
    }, {"key": "proj--m2"})
    assert(!f.recompute_status!())
    assert_eq(Feature.find_by_slug("proj", "mixed").status, "in-progress")
  })
})

describe("FeaturesController CRUD", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    User.delete_all()
    Setting.delete_all()
    User.register("crud@test.com", "password", "CRUD")
    login("crud@test.com", "password")
  })

  test("POST /features creates a feature and redirects", fn() {
    response = post(
      "/features",
      {
        "title": "New Feature",
        "project": "proj",
        "description": "desc",
        "status": "draft"
      },
      {"headers": {"Origin": _publish_origin_for_worker()}}
    )
    assert_eq(res_status(response), 302)
    f = Feature.find_by_slug("proj", "new-feature")
    assert_not_null(f)
    assert_eq(f.title, "New Feature")
  })

  test(
    "POST /features persists version_id when provided",
    fn() {
      Version.delete_all()
      v = Version.create({
        "project": "proj",
        "name": "Cycle 1",
        "status": "active"
      })
      assert(v._errors.nil?)
      response = post(
        "/features",
        {
          "title": "Bet One",
          "project": "proj",
          "status": "draft",
          "version_id": v._key
        },
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 302)
      f = Feature.find_by_slug("proj", "bet-one")
      assert_not_null(f)
      assert_eq(f.version_id, v._key)
    }
  )

  test("POST /features/:id/update updates version_id", fn() {
    Version.delete_all()
    v = Version.create({
      "project": "proj",
      "name": "Cycle Edit",
      "status": "planned"
    })
    Feature.create({
      "project": "proj",
      "slug": "reassign",
      "title": "Reassign",
      "status": "draft"
    }, {"key": "proj--reassign"})
    response = post(
      "/features/proj--reassign/update",
      {"title": "Reassign", "version_id": v._key},
      {"headers": {"Origin": _publish_origin_for_worker()}}
    )
    assert_eq(res_status(response), 302)
    f = Feature.find_by_slug("proj", "reassign")
    assert_eq(f.version_id, v._key)
  })

  test(
    "POST /features/:id/assign-cycle reassigns the cycle",
    fn() {
      Version.delete_all()
      v = Version.create({
        "project": "proj",
        "name": "Inline Cycle",
        "status": "active"
      })
      Feature.create({
        "project": "proj",
        "slug": "inline",
        "title": "Inline",
        "status": "draft"
      }, {"key": "proj--inline"})
      response = post(
        "/features/proj--inline/assign-cycle",
        {"version_id": v._key},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 302)
      f = Feature.find_by_slug("proj", "inline")
      assert_eq(f.version_id, v._key)
    }
  )

  test(
    "POST /features/:id/assign-cycle with empty version_id clears it",
    fn() {
      Version.delete_all()
      v = Version.create({
        "project": "proj",
        "name": "Clear Cycle",
        "status": "active"
      })
      Feature.create({
        "project": "proj",
        "slug": "clear",
        "title": "Clear",
        "status": "draft",
        "version_id": v._key
      }, {"key": "proj--clear"})
      response = post(
        "/features/proj--clear/assign-cycle",
        {"version_id": ""},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 302)
      f = Feature.find_by_slug("proj", "clear")
      assert_eq(f.version_id ?? "", "")
    }
  )

  test(
    "POST /features/:id/assign-cycle rejects unknown cycle",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "badcycle",
        "title": "Bad",
        "status": "draft"
      }, {"key": "proj--badcycle"})
      response = post(
        "/features/proj--badcycle/assign-cycle",
        {"version_id": "no--such--cycle"},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 422)
    }
  )

  test(
    "POST /features/:id/assign-cycle rejects cross-project cycle",
    fn() {
      Version.delete_all()
      other = Version.create({
        "project": "other-proj",
        "name": "Other",
        "status": "active"
      })
      Feature.create({
        "project": "proj",
        "slug": "mismatch",
        "title": "Mismatch",
        "status": "draft"
      }, {"key": "proj--mismatch"})
      response = post(
        "/features/proj--mismatch/assign-cycle",
        {"version_id": other._key},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 422)
    }
  )

  test("POST /features/:id/promote flips draft to ready", fn() {
    Feature.create({
      "project": "proj",
      "slug": "prom",
      "title": "Prom",
      "status": "draft"
    }, {"key": "proj--prom"})
    response = post("/features/proj--prom/promote", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
    assert_eq(res_status(response), 302)
    f = Feature.find_by_slug("proj", "prom")
    assert_eq(f.status, "ready")
  })

  test(
    "POST /features/:id/promote is a no-op when already ready",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "prom-r",
        "title": "PromR",
        "status": "ready"
      }, {"key": "proj--prom-r"})
      response = post("/features/proj--prom-r/promote", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
      assert_eq(res_status(response), 302)
      f = Feature.find_by_slug("proj", "prom-r")
      assert_eq(f.status, "ready")
    }
  )

  test(
    "POST /features/:id/promote can also set the cycle in one step",
    fn() {
      Version.delete_all()
      v = Version.create({
        "project": "proj",
        "name": "Promote Cycle",
        "status": "planned"
      })
      Feature.create({
        "project": "proj",
        "slug": "prom-c",
        "title": "PromC",
        "status": "draft"
      }, {"key": "proj--prom-c"})
      response = post(
        "/features/proj--prom-c/promote",
        {"version_id": v._key},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 302)
      f = Feature.find_by_slug("proj", "prom-c")
      assert_eq(f.status, "ready")
      assert_eq(f.version_id, v._key)
    }
  )

  test(
    "POST /features/:id/promote returns 404 for unknown feature",
    fn() {
      response = post("/features/nope--feat/promote", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
      assert_eq(res_status(response), 404)
    }
  )

  test(
    "POST /features/:id/assign-cycle returns 404 for unknown feature",
    fn() {
      response = post(
        "/features/no-such--feature/assign-cycle",
        {"version_id": ""},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 404)
    }
  )

  test(
    "POST /features returns 422 when project is missing",
    fn() {
      response = post("/features", {"title": "No Project"}, {"headers": {"Origin": _publish_origin_for_worker()}})
      assert_eq(res_status(response), 422)
    }
  )

  test("POST /features/:id/update updates the feature", fn() {
    Feature.create({
      "project": "proj",
      "slug": "update-me",
      "title": "Original",
      "status": "draft"
    }, {"key": "proj--update-me"})
    response = post(
      "/features/proj--update-me/update",
      {"title": "Updated Title"},
      {"headers": {"Origin": _publish_origin_for_worker()}}
    )
    assert_eq(res_status(response), 302)
    f = Feature.find_by_slug("proj", "update-me")
    assert_not_null(f)
    assert_eq(f.title, "Updated Title")
  })

  test("POST /features/:id/destroy deletes the feature", fn() {
    Feature.create({
      "project": "proj",
      "slug": "delete-me",
      "title": "Delete Me",
      "status": "draft"
    }, {"key": "proj--delete-me"})
    response = post("/features/proj--delete-me/destroy", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
    assert_eq(res_status(response), 302)
    assert_null(Feature.find_by_slug("proj", "delete-me"))
  })

  test(
    "POST /features/:id/destroy returns 404 for unknown feature",
    fn() {
      response = post("/features/no-such-feature/destroy", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
      assert_eq(res_status(response), 404)
    }
  )

  test(
    "POST /features/:id/tasks/:slug/remove removes proposed task",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "remove-f",
        "title": "Remove F",
        "status": "draft"
      }, {"key": "proj--remove-f"})
      Task.create({
        "project": "proj",
        "slug": "remove-t",
        "title": "Remove T",
        "status": "proposed",
        "feature_slug": "proj--remove-f"
      }, {"key": "proj--remove-t"})
      response = post(
        "/features/proj--remove-f/tasks/remove-t/remove",
        {},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 302)
      assert_null(Task.find_by_slug("proj", "remove-t"))
    }
  )

  test(
    "POST /features/:id/tasks/:slug/remove returns 422 for non-proposed task",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "remove-f2",
        "title": "Remove F2",
        "status": "draft"
      }, {"key": "proj--remove-f2"})
      Task.create({
        "project": "proj",
        "slug": "remove-t2",
        "title": "Remove T2",
        "status": "todo",
        "feature_slug": "proj--remove-f2"
      }, {"key": "proj--remove-t2"})
      response = post(
        "/features/proj--remove-f2/tasks/remove-t2/remove",
        {},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 422)
    }
  )

  test(
    "POST /features/:id/tasks/:slug/remove returns 404 for unknown task",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "remove-f3",
        "title": "Remove F3",
        "status": "draft"
      }, {"key": "proj--remove-f3"})
      response = post(
        "/features/proj--remove-f3/tasks/no-such-task/remove",
        {},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 404)
    }
  )
})

describe("FeaturesController GET routes", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("get@test.com", "password", "GET User")
    login("get@test.com", "password")
  })

  test("GET /features/:id shows a feature", fn() {
    Feature.create({
      "project": "proj",
      "slug": "show-me",
      "title": "Show Me",
      "status": "draft"
    }, {"key": "proj--show-me"})
    response = get("/features/proj--show-me")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "Show Me")
  })

  test(
    "GET /features/:id returns 404 for unknown feature",
    fn() {
      response = get("/features/no-such-feature")
      assert_eq(res_status(response), 404)
    }
  )

  test("GET /features/new returns 200", fn() {
    response = get("/features/new")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "New Feature Brief")
  })

  test("GET /features/:id/edit shows edit form", fn() {
    Feature.create({
      "project": "proj",
      "slug": "edit-me",
      "title": "Edit Me",
      "status": "draft"
    }, {"key": "proj--edit-me"})
    response = get("/features/proj--edit-me/edit")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "Edit Me")
  })

  test(
    "POST /features/:id/cancel_plan cancels active plan",
    fn() {
      f = Feature.create({
        "project": "proj",
        "slug": "cancel-f",
        "title": "Cancel F",
        "status": "draft"
      }, {"key": "proj--cancel-f"})
      Plan.create({
        "project": "proj",
        "plan_id": "plan--cancel",
        "feature_slug": "proj--cancel-f",
        "status": "starting",
        "prompt": "Feature brief: Cancel F",
        "pid": nil,
        "tasks_imported": false
      }, {"key": "plan--cancel"})
      response = post(
        "/features/proj--cancel-f/cancel_plan",
        {},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 302)
      plan = Plan.find_by_plan_id("plan--cancel")
      assert_not_null(plan)
      assert(plan.status.starts_with("failed:"))
    }
  )

  test(
    "POST /features/:id/publish redirects when no proposed tasks",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "no-proposed",
        "title": "No Proposed",
        "status": "ready"
      }, {"key": "proj--no-proposed"})
      response = post("/features/proj--no-proposed/publish", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
      assert_eq(res_status(response), 302)
    }
  )

  test(
    "POST /features/:id/refine_tasks returns 422 with empty refinement",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "refine",
        "title": "Refine",
        "status": "draft"
      }, {"key": "proj--refine"})
      response = post(
        "/features/proj--refine/refine_tasks",
        {"refinement": ""},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 422)
    }
  )
})

describe("FeaturesController WS stream access control", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    User.delete_all()
  })

  test(
    "read_plan_state returns stream_token for a plan that has one",
    fn() {

      # Plan._key IS the plan_id (set to "plan-NNN" by spawn_plan_agent).
      plan = Plan.create({
        "project": "proj",
        "plan_id": "plan-token-test",
        "status": "running",
        "stream_token": "secret-token-abc"
      }, {"key": "plan-token-test"})
      state = read_plan_state("plan-token-test")
      assert_eq(state["stream_token"], "secret-token-abc")
    }
  )

  test(
    "read_plan_state returns empty stream_token for a plan without one",
    fn() {
      plan = Plan.create({
        "project": "proj",
        "plan_id": "plan-no-token",
        "status": "running"
      }, {"key": "plan-no-token"})
      state = read_plan_state("plan-no-token")
      assert_eq(state["stream_token"], "")
    }
  )

  test(
    "generate_tasks_log renders data-stream-token from the plan",
    fn() {
      f = Feature.create({
        "project": "proj",
        "slug": "feat-log-token",
        "title": "Log Token Feature",
        "status": "ready"
      }, {"key": "proj--feat-log-token"})

      # _key must match what spawn_plan_agent sets: just the plan_id.
      plan = Plan.create({
        "project": "proj",
        "plan_id": "plan-log-token",
        "status": "running",
        "feature_slug": f._key,
        "stream_token": "visible-token-xyz"
      }, {"key": "plan-log-token"})
      User.register("test@example.com", "password123", "Test User")
      login("test@example.com", "password123")
      response = get(
        "/features/proj--feat-log-token/generate_tasks_log/plan-log-token",
        {},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 200)
      body = res_body(response)
      assert_contains(body, "data-stream-token=\"visible-token-xyz\"")
    }
  )
})

describe("FeaturesController#update edge cases", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    User.delete_all()
    User.register("upd@test.com", "password", "Upd")
    login("upd@test.com", "password")
  })

  test(
    "POST /features/:id/update returns 404 for unknown feature",
    fn() {
      response = post(
        "/features/no-such/update",
        {"title": "x"},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 404)
    }
  )

  test(
    "POST /features/:id/update returns 422 when title is empty",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "blank-title",
        "title": "Original",
        "status": "draft"
      }, {"key": "proj--blank-title"})
      response = post(
        "/features/proj--blank-title/update",
        {"title": ""},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 422)
    }
  )

  test(
    "GET /features/:id/edit returns 404 for unknown feature",
    fn() {
      response = get("/features/no-such/edit")
      assert_eq(res_status(response), 404)
    }
  )
})

describe("FeaturesController#generate_tasks 404 + 422", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    User.delete_all()
    User.register("gen@test.com", "password", "Gen")
    login("gen@test.com", "password")
  })

  test("returns 404 for unknown feature", fn() {
    response = post(
      "/features/no-such-feature/generate_tasks",
      {},
      {"headers": {"Origin": _publish_origin_for_worker()}}
    )
    assert_eq(res_status(response), 404)
  })

  test("returns 422 when the feature has no description", fn() {
    Feature.create({
      "project": "proj",
      "slug": "no-desc",
      "title": "No Desc",
      "status": "draft"
    }, {"key": "proj--no-desc"})
    response = post(
      "/features/proj--no-desc/generate_tasks",
      {},
      {"headers": {"Origin": _publish_origin_for_worker()}}
    )
    assert_eq(res_status(response), 422)
  })
})

describe(
  "FeaturesController#regenerate_tasks + refine_tasks 404",
  fn() {
    before_each(fn() {
      assert_test_db()
      Feature.delete_all()
      User.delete_all()
      User.register("regen@test.com", "password", "Regen")
      login("regen@test.com", "password")
    })

    test(
      "regenerate_tasks returns 404 for unknown feature",
      fn() {
        response = post(
          "/features/no-such/regenerate_tasks",
          {},
          {"headers": {"Origin": _publish_origin_for_worker()}}
        )
        assert_eq(res_status(response), 404)
      }
    )

    test("refine_tasks returns 404 for unknown feature", fn() {
      response = post(
        "/features/no-such/refine_tasks",
        {"refinement": "more"},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 404)
    })
  }
)

describe("FeaturesController#cancel_plan edges", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    User.delete_all()
    User.register("cancel@test.com", "password", "Cancel")
    login("cancel@test.com", "password")
  })

  test("returns 404 for unknown feature", fn() {
    response = post("/features/no-such/cancel_plan", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
    assert_eq(res_status(response), 404)
  })

  test(
    "redirects without changes when no plan exists for the feature",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "no-plan",
        "title": "No Plan",
        "status": "draft"
      }, {"key": "proj--no-plan"})
      response = post("/features/proj--no-plan/cancel_plan", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
      assert_eq(res_status(response), 302)
    }
  )

  test(
    "leaves a done plan's status alone but stamps tasks_imported",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "done-plan",
        "title": "Done Plan",
        "status": "draft"
      }, {"key": "proj--done-plan"})
      Plan.create({
        "project": "proj",
        "plan_id": "plan-cancel-done",
        "status": "done",
        "feature_slug": "proj--done-plan",
        "tasks_imported": false
      }, {"key": "plan-cancel-done"})
      response = post(
        "/features/proj--done-plan/cancel_plan",
        {},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 302)
      plan = Plan.find_by_plan_id("plan-cancel-done")
      assert_eq(plan.status, "done")
      assert(plan.tasks_imported == true)
    }
  )
})

describe("FeaturesController#generate_tasks_log", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("log@test.com", "password", "Log")
    login("log@test.com", "password")
  })

  test("returns 404 for unknown feature", fn() {
    response = get("/features/no-such/generate_tasks_log/plan-x")
    assert_eq(res_status(response), 404)
  })

  test("renders streaming progress for a running plan", fn() {
    Feature.create({
      "project": "proj",
      "slug": "polling",
      "title": "Polling",
      "status": "ready"
    }, {"key": "proj--polling"})
    Plan.create({
      "project": "proj",
      "plan_id": "plan-poll",
      "status": "running",
      "feature_slug": "proj--polling",
      "pid": 1,
      "log": "doing work",
      "stream_token": "tk"
    }, {"key": "plan-poll"})
    response = get("/features/proj--polling/generate_tasks_log/plan-poll")
    assert_eq(res_status(response), 200)
    body = res_body(response)
    assert_contains(body, "generate-progress")
    assert_contains(body, "doing work")
  })

  test("renders failed state when the plan has failed", fn() {
    Feature.create({
      "project": "proj",
      "slug": "boom-f",
      "title": "Boom",
      "status": "ready"
    }, {"key": "proj--boom-f"})
    Plan.create({
      "project": "proj",
      "plan_id": "plan-boom",
      "status": "failed:exit-1",
      "feature_slug": "proj--boom-f",
      "log": "broke"
    }, {"key": "plan-boom"})
    response = get("/features/proj--boom-f/generate_tasks_log/plan-boom")
    assert_eq(res_status(response), 200)
    assert_contains(res_body(response), "Plan failed")
  })

  test(
    "imports proposed tasks and signals reload when the plan is done",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "done-import",
        "title": "Done Import",
        "description": "yes",
        "status": "ready"
      }, {"key": "proj--done-import"})
      Plan.create({
        "project": "proj",
        "plan_id": "plan-done-import",
        "status": "done",
        "feature_slug": "proj--done-import",
        "body": "## Task 1: First import\n\nDo this.\n\n## Task 2: Second import\n\nAnd this.",
        "tasks_imported": false
      }, {"key": "plan-done-import"})
      response = get("/features/proj--done-import/generate_tasks_log/plan-done-import")
      assert_eq(res_status(response), 200)
      proposed = Task.where({"feature_slug": "proj--done-import", "status": "proposed"}).all()
      assert_eq(proposed.length(), 2)
      plan = Plan.find_by_plan_id("plan-done-import")
      assert(plan.tasks_imported == true)
    }
  )

  test("renders single-select pending question form", fn() {
    Feature.create({
      "project": "proj",
      "slug": "qs",
      "title": "Q Single",
      "status": "ready"
    }, {"key": "proj--qs"})
    Plan.create({
      "project": "proj",
      "plan_id": "plan-q-single",
      "status": "awaiting",
      "feature_slug": "proj--qs",
      "pending_question": {
        "id": "qid-1",
        "tool": "AskUserQuestion",
        "input": {"questions": [{
          "question": "Pick one?",
          "multiSelect": false,
          "options": [{"label": "Alpha", "description": "First"}, {
            "label": "Beta",
            "description": "Second"
          }]
        }]}
      },
      "pid": 1
    }, {"key": "plan-q-single"})
    response = get("/features/proj--qs/generate_tasks_log/plan-q-single")
    assert_eq(res_status(response), 200)
    body = res_body(response)
    assert_contains(body, "Pick one?")
    assert_contains(body, "Alpha")
    assert_contains(body, "Beta")
  })

  test("renders multi-select pending question form", fn() {
    Feature.create({
      "project": "proj",
      "slug": "qm",
      "title": "Q Multi",
      "status": "ready"
    }, {"key": "proj--qm"})
    Plan.create({
      "project": "proj",
      "plan_id": "plan-q-multi",
      "status": "awaiting",
      "feature_slug": "proj--qm",
      "pending_question": {
        "id": "qid-2",
        "tool": "AskUserQuestion",
        "input": {"questions": [{
          "question": "Pick many?",
          "multiSelect": true,
          "options": [{"label": "Red", "description": ""}, {
            "label": "Green",
            "description": ""
          }]
        }]}
      },
      "pid": 1
    }, {"key": "plan-q-multi"})
    response = get("/features/proj--qm/generate_tasks_log/plan-q-multi")
    assert_eq(res_status(response), 200)
    body = res_body(response)
    assert_contains(body, "Pick many?")
    assert_contains(body, "Submit selection")
  })

  test(
    "imports a single-section plan body via the fallback heading parser",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "solo-import",
        "title": "Solo",
        "description": "x",
        "status": "ready"
      }, {"key": "proj--solo-import"})
      Plan.create({
        "project": "proj",
        "plan_id": "plan-solo",
        "status": "done",
        "feature_slug": "proj--solo-import",
        "body": "# Just one heading\n\nbody content here",
        "tasks_imported": false
      }, {"key": "plan-solo"})
      response = get("/features/proj--solo-import/generate_tasks_log/plan-solo")
      assert_eq(res_status(response), 200)
      proposed = Task.where({"feature_slug": "proj--solo-import", "status": "proposed"}).all()
      assert_eq(proposed.length(), 1)
    }
  )
})

describe("FeaturesController#plan_answer", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("ans@test.com", "password", "Ans")
    login("ans@test.com", "password")
  })

  test("returns 404 for unknown feature", fn() {
    response = post(
      "/features/no-such/plan-answer/plan-x",
      {"qid": "q", "value": "yes"},
      {"headers": {"Origin": _publish_origin_for_worker()}}
    )
    assert_eq(res_status(response), 404)
  })

  test("returns 422 when qid is empty", fn() {
    Feature.create({
      "project": "proj",
      "slug": "ans-empty",
      "title": "Ans Empty",
      "status": "ready"
    }, {"key": "proj--ans-empty"})
    response = post(
      "/features/proj--ans-empty/plan-answer/plan-x",
      {"qid": "", "value": "ok"},
      {"headers": {"Origin": _publish_origin_for_worker()}}
    )
    assert_eq(res_status(response), 422)
  })

  test("returns 422 when value is empty", fn() {
    Feature.create({
      "project": "proj",
      "slug": "ans-value-empty",
      "title": "Ans Value Empty",
      "status": "ready"
    }, {"key": "proj--ans-value-empty"})
    response = post(
      "/features/proj--ans-value-empty/plan-answer/plan-x",
      {"qid": "q", "value": ""},
      {"headers": {"Origin": _publish_origin_for_worker()}}
    )
    assert_eq(res_status(response), 422)
  })

  test(
    "writes the answer onto a running plan and renders progress",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "ans-running",
        "title": "Ans Running",
        "status": "ready"
      }, {"key": "proj--ans-running"})
      Plan.create({
        "project": "proj",
        "plan_id": "plan-ans-running",
        "status": "running",
        "feature_slug": "proj--ans-running",
        "pid": 1,
        "stream_token": "tk"
      }, {"key": "plan-ans-running"})
      response = post(
        "/features/proj--ans-running/plan-answer/plan-ans-running",
        {"qid": "q1", "value": "yes"},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 200)
      plan = Plan.find_by_plan_id("plan-ans-running")
      assert_eq(plan.pending_question["id"], "q1")
      assert_eq(plan.pending_question["value"], "yes")
    }
  )

  test(
    "imports tasks and redirects when the answer arrives after the plan finishes",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "ans-done",
        "title": "Ans Done",
        "status": "ready"
      }, {"key": "proj--ans-done"})
      Plan.create({
        "project": "proj",
        "plan_id": "plan-ans-done",
        "status": "done",
        "feature_slug": "proj--ans-done",
        "body": "## Task 1: Late\n\nAfter the fact.",
        "tasks_imported": false
      }, {"key": "plan-ans-done"})
      response = post(
        "/features/proj--ans-done/plan-answer/plan-ans-done",
        {"qid": "q1", "value": "yes"},
        {"headers": {"Origin": _publish_origin_for_worker()}}
      )
      assert_eq(res_status(response), 200)
      imported = Task.where({"feature_slug": "proj--ans-done", "status": "proposed"}).all()
      assert_eq(imported.length(), 1)
    }
  )
})

describe("FeaturesController#show wider state", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    Comment.delete_all()
    User.delete_all()
    User.register("show@test.com", "password", "Show")
    login("show@test.com", "password")
  })

  test(
    "splits tasks into proposed and linked buckets in the show page",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "mix",
        "title": "Mix",
        "description": "x",
        "status": "ready"
      }, {"key": "proj--mix"})
      Task.create({
        "project": "proj",
        "slug": "mix-prop",
        "title": "Proposed One",
        "status": "proposed",
        "feature_slug": "proj--mix"
      }, {"key": "proj--mix-prop"})
      Task.create({
        "project": "proj",
        "slug": "mix-todo",
        "title": "Linked One",
        "status": "todo",
        "feature_slug": "proj--mix"
      }, {"key": "proj--mix-todo"})
      Comment.create_comment("proj--mix", "show@test.com", "Looks nice")
      response = get("/features/proj--mix")
      assert_eq(res_status(response), 200)
      body = res_body(response)
      assert_contains(body, "Proposed One")
      assert_contains(body, "Linked One")
      assert_contains(body, "Looks nice")
    }
  )

  test(
    "finalizes a done-but-unimported plan when the feature page is rendered",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "finalize",
        "title": "Finalize Plan",
        "description": "yep",
        "status": "ready"
      }, {"key": "proj--finalize"})
      Plan.create({
        "project": "proj",
        "plan_id": "plan-finalize",
        "status": "done",
        "feature_slug": "proj--finalize",
        "body": "## Task 1: From plan\n\nDetails.",
        "tasks_imported": false
      }, {"key": "plan-finalize"})
      response = get("/features/proj--finalize")
      assert_eq(res_status(response), 200)
      plan = Plan.find_by_plan_id("plan-finalize")
      assert(plan.tasks_imported == true)
      imported = Task.where({"feature_slug": "proj--finalize", "status": "proposed"}).all()
      assert_eq(imported.length(), 1)
    }
  )

  test(
    "finalizes a done plan matched by prompt prefix when feature_slug is unset",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "prefix-match",
        "title": "Prefix Match",
        "description": "yes",
        "status": "ready"
      }, {"key": "proj--prefix-match"})

      # Older plans don't carry feature_slug — they match by the
      # "Feature brief: <title>" prompt prefix instead.
      Plan.create({
        "project": "proj",
        "plan_id": "plan-prefix",
        "status": "done",
        "prompt": "Feature brief: Prefix Match\n\nyes",
        "body": "## Task 1: Prefix Imported\n\nbody.",
        "tasks_imported": false
      }, {"key": "plan-prefix"})
      response = get("/features/proj--prefix-match")
      assert_eq(res_status(response), 200)
      plan = Plan.find_by_plan_id("plan-prefix")
      assert(plan.tasks_imported == true)
    }
  )
})

describe("FeaturesController#new with project param", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    User.delete_all()
    User.register("new@test.com", "password", "New")
    login("new@test.com", "password")
  })

  test(
    "GET /features/new with ?project= renders without crashing on a missing project",
    fn() {
      response = get("/features/new?project=nonexistent")
      assert_eq(res_status(response), 200)
    }
  )
})

describe(
  "FeaturesController#create + update error paths",
  fn() {
    before_each(fn() {
      assert_test_db()
      Feature.delete_all()
      User.delete_all()
      User.register("err@test.com", "password", "Err")
      login("err@test.com", "password")
    })

    test(
      "POST /features stores plan_model when supplied via the form",
      fn() {
        response = post(
          "/features",
          {
            "title": "With Model",
            "project": "projmodel",
            "status": "draft",
            "plan_model": "claude-opus-4-7"
          },
          {"headers": {"Origin": _publish_origin_for_worker()}}
        )
        assert_eq(res_status(response), 302)
        f = Feature.find_by_slug("projmodel", "with-model")
        assert_not_null(f)
        assert_eq(f.plan_model, "claude-opus-4-7")
      }
    )

    test(
      "POST /features/:id/update accepts a plan_model field",
      fn() {
        Feature.create({
          "project": "proj",
          "slug": "upd-model",
          "title": "Upd Model",
          "status": "draft"
        }, {"key": "proj--upd-model"})
        response = post(
          "/features/proj--upd-model/update",
          {"title": "Upd Model", "plan_model": "claude-haiku-4-5-20251001"},
          {"headers": {"Origin": _publish_origin_for_worker()}}
        )
        assert_eq(res_status(response), 302)
        f = Feature.find_by_slug("proj", "upd-model")
        assert_eq(f.plan_model, "claude-haiku-4-5-20251001")
      }
    )
  }
)

describe("FeaturesController#publish with description", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("desc@test.com", "password", "Desc")
    login("desc@test.com", "password")
  })

  test(
    "renders the feature description as a header in the combined task body",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "with-desc",
        "title": "Featured",
        "description": "Why we want it.",
        "status": "ready"
      }, {"key": "proj--with-desc"})
      Task.create({
        "project": "proj",
        "slug": "prop-desc-1",
        "title": "Build it",
        "body_md": "details",
        "status": "proposed",
        "feature_slug": "proj--with-desc"
      }, {"key": "proj--prop-desc-1"})
      response = post("/features/proj--with-desc/publish", {}, {"headers": {"Origin": _publish_origin_for_worker()}})
      assert_eq(res_status(response), 302)
      parent = Task.find_by_slug("proj", "featured")
      assert_not_null(parent)
      # The combined body starts with the feature title + description block.
      assert_contains(parent.body_md, "# Featured")
      assert_contains(parent.body_md, "Why we want it.")
      assert_contains(parent.body_md, "## Task 1: Build it")
    }
  )
})

describe(
  "FeaturesController#generate_tasks_log idempotency + parser fallbacks",
  fn() {
    before_each(fn() {
      assert_test_db()
      Feature.delete_all()
      Plan.delete_all()
      Task.delete_all()
      User.delete_all()
      User.register("idem@test.com", "password", "Idem")
      login("idem@test.com", "password")
    })

    test(
      "re-polling a done + already-imported plan is a no-op (no duplicate tasks)",
      fn() {
        Feature.create({
          "project": "proj",
          "slug": "idem",
          "title": "Idem",
          "description": "x",
          "status": "ready"
        }, {"key": "proj--idem"})
        Plan.create({
          "project": "proj",
          "plan_id": "plan-idem",
          "status": "done",
          "feature_slug": "proj--idem",
          "body": "## Task 1: Once\n\nonly.",
          "tasks_imported": true,
          "imported_task_count": 1
        }, {"key": "plan-idem"})
        Task.create({
          "project": "proj",
          "slug": "once",
          "title": "Once",
          "status": "proposed",
          "feature_slug": "proj--idem"
        }, {"key": "proj--once"})
        response = get("/features/proj--idem/generate_tasks_log/plan-idem")
        assert_eq(res_status(response), 200)
        # Already-imported plan must not re-import: still exactly one task.
        tasks = Task.where({"feature_slug": "proj--idem", "status": "proposed"}).all()
        assert_eq(tasks.length(), 1)
      }
    )

    test(
      "uses a level-2 heading as the fallback title when the body has no '## Task' marker",
      fn() {
        Feature.create({
          "project": "proj",
          "slug": "h2",
          "title": "H2 Fallback",
          "description": "x",
          "status": "draft"
        }, {"key": "proj--h2"})
        Plan.create({
          "project": "proj",
          "plan_id": "plan-h2",
          "status": "done",
          "feature_slug": "proj--h2",
          "body": "## Some subheading\n\nbody.",
          "tasks_imported": false
        }, {"key": "plan-h2"})
        response = get("/features/proj--h2/generate_tasks_log/plan-h2")
        assert_eq(res_status(response), 200)
        proposed = Task.where({"feature_slug": "proj--h2", "status": "proposed"}).all()
        assert_eq(proposed.length(), 1)
        assert_eq(proposed[0].title, "Some subheading")
        # A draft feature flips to "ready" once tasks are imported.
        f = Feature.find_by_slug("proj", "h2")
        assert_eq(f.status, "ready")
      }
    )

    test(
      "uses the first non-blank line as a fallback title when no heading is present",
      fn() {
        Feature.create({
          "project": "proj",
          "slug": "noheading",
          "title": "No Heading",
          "description": "x",
          "status": "draft"
        }, {"key": "proj--noheading"})
        Plan.create({
          "project": "proj",
          "plan_id": "plan-nh",
          "status": "done",
          "feature_slug": "proj--noheading",
          "body": "just one short paragraph",
          "tasks_imported": false
        }, {"key": "plan-nh"})
        response = get("/features/proj--noheading/generate_tasks_log/plan-nh")
        assert_eq(res_status(response), 200)
        proposed = Task.where({"feature_slug": "proj--noheading", "status": "proposed"}).all()
        assert_eq(proposed.length(), 1)
        assert_eq(proposed[0].title, "just one short paragraph")
      }
    )

    test(
      "truncates an over-long first line in the fallback title",
      fn() {
        Feature.create({
          "project": "proj",
          "slug": "long",
          "title": "Long Line",
          "description": "x",
          "status": "draft"
        }, {"key": "proj--long"})
        long = "this is a deliberately very long single line that "
        + "should be truncated by the fallback title helper "
        + "because it exceeds sixty characters"
        Plan.create({
          "project": "proj",
          "plan_id": "plan-long",
          "status": "done",
          "feature_slug": "proj--long",
          "body": long,
          "tasks_imported": false
        }, {"key": "plan-long"})
        response = get("/features/proj--long/generate_tasks_log/plan-long")
        assert_eq(res_status(response), 200)
        proposed = Task.where({"feature_slug": "proj--long", "status": "proposed"}).all()
        assert_eq(proposed.length(), 1)
        # Title is truncated with an ellipsis suffix.
        assert(proposed[0].title.ends_with("..."))
        assert(proposed[0].title.length() <= 65)
      }
    )

    test(
      "renders option descriptions when the multi-select question carries them",
      fn() {
        Feature.create({
          "project": "proj",
          "slug": "qm-desc",
          "title": "Q Multi w/ desc",
          "status": "ready"
        }, {"key": "proj--qm-desc"})
        Plan.create({
          "project": "proj",
          "plan_id": "plan-qm-desc",
          "status": "awaiting",
          "feature_slug": "proj--qm-desc",
          "pending_question": {
            "id": "qm-desc",
            "tool": "AskUserQuestion",
            "input": {"questions": [{
              "question": "Pick many with desc?",
              "multiSelect": true,
              "options": [{"label": "Apple", "description": "the fruit"}, {
                "label": "Pear",
                "description": "also a fruit"
              }]
            }]}
          },
          "pid": 1
        }, {"key": "plan-qm-desc"})
        response = get("/features/proj--qm-desc/generate_tasks_log/plan-qm-desc")
        assert_eq(res_status(response), 200)
        body = res_body(response)
        assert_contains(body, "the fruit")
        assert_contains(body, "also a fruit")
      }
    )
  }
)

describe("FeaturesController#show with active plan", fn() {
  before_each(fn() {
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
    User.delete_all()
    User.register("active@test.com", "password", "Active")
    login("active@test.com", "password")
  })

  test(
    "surfaces an in-flight plan tied by feature_slug as the active plan",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "with-active",
        "title": "Has Active",
        "description": "x",
        "status": "ready"
      }, {"key": "proj--with-active"})

      # `pid: 1` (init) reliably reports alive on Linux test hosts, so
      # `effective_status` returns "running" instead of synthesizing a zombie.
      Plan.create({
        "project": "proj",
        "plan_id": "plan-active",
        "status": "running",
        "feature_slug": "proj--with-active",
        "pid": 1,
        "stream_token": "tk"
      }, {"key": "plan-active"})
      response = get("/features/proj--with-active")
      assert_eq(res_status(response), 200)
    }
  )

  test(
    "falls back to prompt-prefix matching when an in-flight plan lacks feature_slug",
    fn() {
      Feature.create({
        "project": "proj",
        "slug": "prefix-active",
        "title": "Prefix Active",
        "description": "x",
        "status": "ready"
      }, {"key": "proj--prefix-active"})

      # No feature_slug — must be matched via the "Feature brief: <title>"
      # prompt prefix instead. Plan is still running so _finalize_done_plans
      # leaves it alone and _latest_plan_for / _active_plan_for traverse
      # the second (prompt-based) lookup loop.
      Plan.create({
        "project": "proj",
        "plan_id": "plan-prefix-active",
        "status": "running",
        "prompt": "Feature brief: Prefix Active\n\nx",
        "pid": 1,
        "stream_token": "tk"
      }, {"key": "plan-prefix-active"})
      response = get("/features/proj--prefix-active")
      assert_eq(res_status(response), 200)
    }
  )
})

describe(
  "FeaturesController#generate_tasks_log slug collision",
  fn() {
    before_each(fn() {
      assert_test_db()
      Feature.delete_all()
      Plan.delete_all()
      Task.delete_all()
      User.delete_all()
      User.register("slug@test.com", "password", "Slug")
      login("slug@test.com", "password")
    })

    test(
      "import picks a numbered slug when the derived base collides",
      fn() {
        Feature.create({
          "project": "proj",
          "slug": "collide-f",
          "title": "Collide F",
          "description": "x",
          "status": "draft"
        }, {"key": "proj--collide-f"})

        # Pre-seed a task whose slug matches what the parser would derive
        # from the plan section title — forces _unique_slug_local to bump.
        Task.create({
          "project": "proj",
          "slug": "collide-task",
          "title": "Existing",
          "status": "todo"
        }, {"key": "proj--collide-task"})
        Plan.create({
          "project": "proj",
          "plan_id": "plan-collide",
          "status": "done",
          "feature_slug": "proj--collide-f",
          "body": "## Task 1: Collide task\n\nbody.",
          "tasks_imported": false
        }, {"key": "plan-collide"})
        response = get("/features/proj--collide-f/generate_tasks_log/plan-collide")
        assert_eq(res_status(response), 200)
        proposed = Task.where({"feature_slug": "proj--collide-f", "status": "proposed"}).all()
        assert_eq(proposed.length(), 1)
        # New task takes the "collide-task-2" slug to avoid colliding with the seeded one.
        assert_eq(proposed[0].slug, "collide-task-2")
      }
    )
  }
)

describe(
  "FeaturesController#remove_task wrong feature link",
  fn() {
    before_each(fn() {
      assert_test_db()
      Feature.delete_all()
      Task.delete_all()
      User.delete_all()
      User.register("link@test.com", "password", "Link")
      login("link@test.com", "password")
    })

    test(
      "POST /features/:id/tasks/:slug/remove returns 422 when the task belongs to a different feature",
      fn() {
        Feature.create({
          "project": "proj",
          "slug": "alpha",
          "title": "Alpha",
          "status": "draft"
        }, {"key": "proj--alpha"})
        Feature.create({
          "project": "proj",
          "slug": "beta",
          "title": "Beta",
          "status": "draft"
        }, {"key": "proj--beta"})

        # Task is linked to alpha but the request targets beta.
        Task.create({
          "project": "proj",
          "slug": "alpha-task",
          "title": "Alpha Task",
          "status": "proposed",
          "feature_slug": "proj--alpha"
        }, {"key": "proj--alpha-task"})
        response = post(
          "/features/proj--beta/tasks/alpha-task/remove",
          {},
          {"headers": {"Origin": _publish_origin_for_worker()}}
        )
        assert_eq(res_status(response), 422)
      }
    )
  }
)
