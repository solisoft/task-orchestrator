# ActivityLog model — covers CRUD, the touch_timestamps hook, and the
# integration with Task#_notify_if_status_changed / Feature#touch_timestamps:
# every real status flip with `change_author` set writes an
# ActivityLog row whose from/to/changed_by fields match the transition.

describe("ActivityLog model", fn()
  before_each(fn()
    assert_test_db()
    ActivityLog.delete_all()
  end)

  test("create stamps changed_at when missing", fn()
    let row = ActivityLog.create({
      "task_key":   "proj--row1",
      "to_status":  "queued"
    })
    assert(row._errors == nil)
    assert_not_null(row.changed_at)
    assert(row.changed_at != "")
  end)

  test("validates to_status presence", fn()
    let row = ActivityLog.create({})
    assert(row._errors != nil)
  end)

  test("log_status_change persists the full transition tuple", fn()
    let row = ActivityLog.log_status_change(
      "proj--alpha", nil, "todo", "queued", "alice@example.com"
    )
    assert(row._errors == nil)
    assert_eq(row.task_key, "proj--alpha")
    assert_null(row.feature_key)
    assert_eq(row.from_status, "todo")
    assert_eq(row.to_status, "queued")
    assert_eq(row.changed_by, "alice@example.com")
    assert_not_null(row.changed_at)
  end)

  test("log_status_change coerces nil changed_by to empty string", fn()
    let row = ActivityLog.log_status_change(
      "proj--beta", nil, "todo", "queued", nil
    )
    assert_eq(row.changed_by, "")
  end)

  test("for_task returns activity newest-first", fn()
    ActivityLog.create({
      "task_key":   "proj--key",
      "from_status": "todo",
      "to_status":   "queued",
      "changed_at":  "2026-05-13T10:00:00Z"
    })
    ActivityLog.create({
      "task_key":   "proj--key",
      "from_status": "queued",
      "to_status":   "inprogress",
      "changed_at":  "2026-05-13T11:00:00Z"
    })
    let rows = ActivityLog.for_task("proj--key")
    assert_eq(rows.length(), 2)
    assert_eq(rows[0].to_status, "inprogress")
    assert_eq(rows[1].to_status, "queued")
  end)

  test("for_feature scopes to feature_key", fn()
    ActivityLog.create({
      "feature_key": "proj--feat",
      "from_status": "draft",
      "to_status":   "ready",
      "changed_at":  "2026-05-13T10:00:00Z"
    })
    ActivityLog.create({
      "feature_key": "proj--other",
      "from_status": "draft",
      "to_status":   "ready",
      "changed_at":  "2026-05-13T10:00:00Z"
    })
    let rows = ActivityLog.for_feature("proj--feat")
    assert_eq(rows.length(), 1)
    assert_eq(rows[0].feature_key, "proj--feat")
  end)
end)

# Helper: rows from this spec only, so other specs touching the
# `activity_logs` collection don't bleed into our counts.
def _al_for_task(key)
  let rows = ActivityLog.for_task(key)
  let out = []
  for r in rows
    out.push(r)
  end
  return out
end

describe("Task → ActivityLog integration", fn()
  before_each(fn()
    assert_test_db()
    ActivityLog.delete_all()
    for t in Task.where({ "project": "al" }).all()
      Task.delete(t._key) rescue null
    end
  end)

  test("creates a row when a Task status flips", fn()
    Task.create({
      "_key":    "al--t1",
      "project": "al",
      "slug":    "t1",
      "title":   "alpha",
      "status":  "todo"
    })
    assert_eq(_al_for_task("al--t1").length(), 0)
    let t = Task.find_by_slug("al", "t1")
    t.change_author = "alice@example.com"
    t.status = "queued"
    t.save()
    let rows = _al_for_task("al--t1")
    assert_eq(rows.length(), 1)
    assert_eq(rows[0].from_status, "todo")
    assert_eq(rows[0].to_status, "queued")
    assert_eq(rows[0].changed_by, "alice@example.com")
  end)

  test("does not write a row on initial Task create", fn()
    Task.create({
      "_key":    "al--fresh",
      "project": "al",
      "slug":    "fresh",
      "title":   "fresh",
      "status":  "todo"
    })
    assert_eq(_al_for_task("al--fresh").length(), 0)
  end)

  test("does not write a row when save() does not change status", fn()
    Task.create({
      "_key":    "al--same",
      "project": "al",
      "slug":    "same",
      "title":   "same",
      "status":  "todo"
    })
    let t = Task.find_by_slug("al", "same")
    t.title = "renamed"
    t.change_author = "alice@example.com"
    t.save()
    assert_eq(_al_for_task("al--same").length(), 0)
  end)

  test("stamps an empty changed_by when no change_author is set", fn()
    Task.create({
      "_key":    "al--anon",
      "project": "al",
      "slug":    "anon",
      "title":   "anon",
      "status":  "todo"
    })
    let t = Task.find_by_slug("al", "anon")
    t.status = "queued"
    t.save()
    let rows = _al_for_task("al--anon")
    assert_eq(rows.length(), 1)
    assert_eq(rows[0].changed_by, "")
  end)

  test("logs the feature_key on the row when the task is linked to a feature", fn()
    Task.create({
      "_key":         "al--linked",
      "project":      "al",
      "slug":         "linked",
      "title":        "linked",
      "status":       "todo",
      "feature_slug": "al--brief"
    })
    let t = Task.find_by_slug("al", "linked")
    t.change_author = "bob@example.com"
    t.status = "queued"
    t.save()
    let rows = _al_for_task("al--linked")
    assert_eq(rows.length(), 1)
    assert_eq(rows[0].feature_key, "al--brief")
  end)
end)

describe("Feature → ActivityLog integration", fn()
  before_each(fn()
    assert_test_db()
    ActivityLog.delete_all()
    Feature.delete_all()
  end)

  test("creates a row when a Feature status flips", fn()
    Feature.create({
      "_key":    "fa--f1",
      "project": "fa",
      "slug":    "f1",
      "title":   "F1",
      "status":  "draft"
    })
    assert_eq(ActivityLog.for_feature("fa--f1").length(), 0)
    let f = Feature.find_by_slug("fa", "f1")
    f.change_author = "carol@example.com"
    f.status = "ready"
    f.save()
    let rows = ActivityLog.for_feature("fa--f1")
    assert_eq(rows.length(), 1)
    assert_eq(rows[0].from_status, "draft")
    assert_eq(rows[0].to_status, "ready")
    assert_eq(rows[0].changed_by, "carol@example.com")
  end)

  test("does not write a row on initial Feature create", fn()
    Feature.create({
      "_key":    "fa--fresh",
      "project": "fa",
      "slug":    "fresh",
      "title":   "F",
      "status":  "draft"
    })
    assert_eq(ActivityLog.for_feature("fa--fresh").length(), 0)
  end)
end)
