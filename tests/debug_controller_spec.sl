describe("DebugController", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Plan.delete_all()
    Task.delete_all()
  end)

  describe("GET /debug", fn()
    test("returns 200", fn()
      let response = get("/debug")
      assert_eq(res_status(response), 200)
    end)

    test("body contains task count info", fn()
      let response = get("/debug")
      assert_contains(res_body(response), "Task.count()")
    end)
  end)

  describe("GET /debug/features", fn()
    test("returns 200", fn()
      let response = get("/debug/features")
      assert_eq(res_status(response), 200)
    end)

    test("body contains features section", fn()
      let response = get("/debug/features")
      assert_contains(res_body(response), "FEATURES")
    end)

    test("body contains plans section", fn()
      let response = get("/debug/features")
      assert_contains(res_body(response), "PLANS")
    end)
  end)

  describe("GET /debug/comments", fn()
    test("returns 200", fn()
      let response = get("/debug/comments")
      assert_eq(res_status(response), 200)
    end)

    test("body contains COMMENTS section header", fn()
      let response = get("/debug/comments")
      assert_contains(res_body(response), "COMMENTS")
    end)
  end)

  describe("GET /debug/demote", fn()
    test("returns 422 without feature param", fn()
      let response = get("/debug/demote")
      assert_eq(res_status(response), 422)
    end)

    test("returns 422 with empty feature param", fn()
      let response = get("/debug/demote?feature=")
      assert_eq(res_status(response), 422)
    end)

    test("returns 200 with valid feature param", fn()
      Feature.create({
        "_key":    "proj--demote-feat",
        "project": "proj",
        "slug":    "demote-feat",
        "title":   "Demote Feature",
        "status":  "in-progress"
      })
      Task.create({
        "_key":         "proj--task-demote",
        "project":      "proj",
        "slug":         "task-demote",
        "title":        "Task",
        "status":       "todo",
        "feature_slug": "proj--demote-feat"
      })
      let response = get("/debug/demote?feature=proj--demote-feat")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "demoted")
    end)
  end)

  describe("GET /debug/stamp", fn()
    test("returns 422 without feature param", fn()
      let response = get("/debug/stamp")
      assert_eq(res_status(response), 422)
    end)

    test("returns 200 with valid feature param", fn()
      Feature.create({
        "_key":       "proj--stamp-feat",
        "project":    "proj",
        "slug":       "stamp-feat",
        "title":      "Stamp Feature",
        "status":     "ready"
      })
      Plan.create({
        "_key":         "plan--stamp-1",
        "plan_id":      "stamp-plan-1",
        "project":      "proj",
        "feature_slug": "proj--stamp-feat",
        "status":       "done",
        "tasks_imported": false,
        "prompt":       "Feature brief: Stamp Feature"
      })
      let response = get("/debug/stamp?feature=proj--stamp-feat")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "stamped")
    end)
  end)

  describe("GET /debug/unstamp", fn()
    test("returns 422 without feature param", fn()
      let response = get("/debug/unstamp")
      assert_eq(res_status(response), 422)
    end)

    test("returns 200 with valid feature param", fn()
      Feature.create({
        "_key":       "proj--unstamp-feat",
        "project":    "proj",
        "slug":       "unstamp-feat",
        "title":      "Unstamp Feature",
        "status":     "ready"
      })
      Plan.create({
        "_key":           "plan--unstamp-1",
        "plan_id":        "unstamp-plan-1",
        "project":        "proj",
        "feature_slug":   "proj--unstamp-feat",
        "status":         "done",
        "tasks_imported": true,
        "prompt":         "Feature brief: Unstamp Feature"
      })
      let response = get("/debug/unstamp?feature=proj--unstamp-feat")
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "unstamped")
    end)
  end)

  describe("GET /debug/try-import", fn()
    test("returns 422 without feature param", fn()
      let response = get("/debug/try-import")
      assert_eq(res_status(response), 422)
    end)

    test("returns 404 for unknown feature", fn()
      let response = get("/debug/try-import?feature=nonexistent--feat")
      assert_eq(res_status(response), 404)
    end)

    test("returns 200 with valid feature", fn()
      Feature.create({
        "_key":    "proj--try-import-feat",
        "project": "proj",
        "slug":    "try-import-feat",
        "title":   "Try Import Feature",
        "status":  "ready"
      })
      let response = get("/debug/try-import?feature=proj--try-import-feat")
      assert_eq(res_status(response), 200)
    end)
  end)
end)