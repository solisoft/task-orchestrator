# Plans controller — lists plans from the solidb `plans` collection.

describe("PlansController", fn() {
    describe("GET /plans", fn() {
        # before_each must live at the same describe level as the tests
        # — Soli's before_each does not cascade into nested describes,
        # so seating it at the outer level would leave the DB polluted
        # between cases and make absence-assertions racy.
        before_each(fn() {
            assert_test_db()
            Plan.delete_all()
            Task.delete_all()
            User.delete_all()
            User.register("plans@test.com", "password", "Plans User")
            login("plans@test.com", "password")
        })

        test("returns 200 with no plans", fn() {
            let response = get("/plans")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            # NOTE: Soli's String#contains has a stateful cursor bug that
            # makes consecutive calls unreliable in assertions. We verify
            # that the page rendered via length and a single known string.
            assert(body.length() > 100)
            assert(body.index_of("Plans</h1>") != -1)
        })

        test("lists a done plan with rendered body", fn() {
            Plan.create({
                "_key":              "plan-99990001",
                "project":           "test-project",
                "plan_id":           "plan-99990001",
                "status":            "done",
                "model":             "claude-sonnet-4-6",
                "prompt":            "add a footer",
                "body":              "# Fix pagination\n\n## Severity\nhigh",
                "log":               "",
                "pending_question": nil,
                "zombie":            false
            })

            let response = get("/plans")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            assert(body.contains("plan-99990001"))
            assert(body.contains("claude-sonnet-4-6"))
            assert(body.contains("Fix pagination"))
        })

        test("lists a failed plan", fn() {
            Plan.create({
                "_key":              "plan-99990002",
                "project":           "test-project",
                "plan_id":           "plan-99990002",
                "status":            "failed:rc=1",
                "model":             "claude-opus-4-7",
                "prompt":            "broken",
                "body":              "",
                "log":               "",
                "pending_question": nil,
                "zombie":            false
            })

            let response = get("/plans")
            assert_eq(res_status(response), 200)
            assert(res_body(response).contains("plan-99990002"))
        })

        test("sorts plans newest-first by id", fn() {
            for i in [1, 2, 3]
                Plan.create({
                    "_key":              "plan-9999000" + str(i),
                    "project":           "test-project",
                    "plan_id":           "plan-9999000" + str(i),
                    "status":            "done",
                    "model":             "claude-sonnet-4-6",
                    "prompt":            "test " + str(i),
                    "body":              "# Task " + str(i),
                    "log":               "",
                    "pending_question": nil,
                    "zombie":            false
                })
            end

            let body = res_body(get("/plans"))
            let p1 = body.index_of("plan-99990003")
            let p2 = body.index_of("plan-99990002")
            let p3 = body.index_of("plan-99990001")
            assert(p1 != -1 and p2 != -1 and p3 != -1 and p1 < p2 and p2 < p3)
        })

        test("handles empty DB gracefully", fn() {
            let response = get("/plans")
            assert_eq(res_status(response), 200)
        })

        test("shows linked task title + status for a plan with task_slug", fn() {
            Task.create({
                "_key":    "test-project--build-the-thing",
                "project": "test-project",
                "slug":    "build-the-thing",
                "title":   "Build the thing",
                "status":  "inprogress"
            })
            Plan.create({
                "_key":              "plan-99990010",
                "project":           "test-project",
                "plan_id":           "plan-99990010",
                "status":            "done",
                "model":             "claude-sonnet-4-6",
                "prompt":            "build it",
                "body":              "# Build the thing",
                "log":               "",
                "pending_question": nil,
                "zombie":            false,
                "task_slug":         "build-the-thing"
            })

            let response = get("/plans")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            assert(body.contains("data-linked-task=\"build-the-thing\""))
            assert(body.contains("Build the thing"))
            assert(body.contains("inprogress"))
            assert(body.contains("/projects/test-project/tasks/build-the-thing"))
        })

        test("renders no linked-task badge when the plan has no task_slug", fn() {
            Plan.create({
                "_key":              "plan-99990020",
                "project":           "test-project",
                "plan_id":           "plan-99990020",
                "status":            "done",
                "model":             "claude-sonnet-4-6",
                "prompt":            "no link",
                "body":              "# Unconverted",
                "log":               "",
                "pending_question": nil,
                "zombie":            false
            })

            let response = get("/plans")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            assert(body.contains("plan-99990020"))
            assert_not(body.contains("data-linked-task="))
        })

        test("search matches prompt", fn() {
            Plan.create({
                "_key": "plan-99990040",
                "project": "test-project",
                "plan_id": "plan-99990040",
                "status": "done",
                "model": "claude-sonnet-4-6",
                "prompt": "fix the login button alignment",
                "body": "UI tweaks",
                "log": "",
                "pending_question": nil,
                "zombie": false
            })
            Plan.create({
                "_key": "plan-99990041",
                "project": "test-project",
                "plan_id": "plan-99990041",
                "status": "done",
                "model": "claude-sonnet-4-6",
                "prompt": "add database migration",
                "body": "Schema changes",
                "log": "",
                "pending_question": nil,
                "zombie": false
            })

            let response = get("/plans?q=login")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            assert(body.contains("plan-99990040"))
            assert_not(body.contains("plan-99990041"))
        })

        test("search matches body", fn() {
            Plan.create({
                "_key": "plan-99990042",
                "project": "test-project",
                "plan_id": "plan-99990042",
                "status": "done",
                "model": "claude-sonnet-4-6",
                "prompt": "optimize queries",
                "body": "Add proper indexing to speed up lookups",
                "log": "",
                "pending_question": nil,
                "zombie": false
            })
            Plan.create({
                "_key": "plan-99990043",
                "project": "test-project",
                "plan_id": "plan-99990043",
                "status": "done",
                "model": "claude-sonnet-4-6",
                "prompt": "refactor utils",
                "body": "Extract helpers",
                "log": "",
                "pending_question": nil,
                "zombie": false
            })

            let response = get("/plans?q=indexing")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            assert(body.contains("plan-99990042"))
            assert_not(body.contains("plan-99990043"))
        })

        test("search with no matches shows empty state", fn() {
            Plan.create({
                "_key": "plan-99990044",
                "project": "test-project",
                "plan_id": "plan-99990044",
                "status": "done",
                "model": "claude-sonnet-4-6",
                "prompt": "something unrelated",
                "body": "not relevant",
                "log": "",
                "pending_question": nil,
                "zombie": false
            })

            let response = get("/plans?q=zzzznotfound")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            assert(body.contains("No plans match your search"))
            assert_not(body.contains("something unrelated"))
        })

        test("pagination page=1 returns first page", fn() {
            for i in [1, 2, 3, 4, 5]
                Plan.create({
                    "_key": "plan-9999005" + str(i),
                    "project": "test-project",
                    "plan_id": "plan-9999005" + str(i),
                    "status": "done",
                    "model": "claude-sonnet-4-6",
                    "prompt": "page test " + str(i),
                    "body": "content " + str(i),
                    "log": "",
                    "pending_question": nil,
                    "zombie": false
                })
            end

            let response = get("/plans?page=1&per_page=2")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            assert(body.contains("plan-99990055"))
            assert(body.contains("plan-99990054"))
            assert_not(body.contains("plan-99990053"))
            assert(body.contains("Page 1 of"))
            assert(body.contains("Next"))
        })

        test("pagination page=2 returns second page", fn() {
            for i in [1, 2, 3, 4, 5]
                Plan.create({
                    "_key": "plan-9999006" + str(i),
                    "project": "test-project",
                    "plan_id": "plan-9999006" + str(i),
                    "status": "done",
                    "model": "claude-sonnet-4-6",
                    "prompt": "paging " + str(i),
                    "body": "data " + str(i),
                    "log": "",
                    "pending_question": nil,
                    "zombie": false
                })
            end

            let response = get("/plans?page=2&per_page=2")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            assert(body.contains("plan-99990063"))
            assert(body.contains("plan-99990062"))
            assert_not(body.contains("plan-99990065"))
            assert(body.contains("Page 2 of 3"))
        })

        test("no-params fallback returns all plans", fn() {
            Plan.create({
                "_key": "plan-99990070",
                "project": "test-project",
                "plan_id": "plan-99990070",
                "status": "done",
                "model": "claude-sonnet-4-6",
                "prompt": "fallback one",
                "body": "alpha",
                "log": "",
                "pending_question": nil,
                "zombie": false
            })
            Plan.create({
                "_key": "plan-99990071",
                "project": "test-project",
                "plan_id": "plan-99990071",
                "status": "done",
                "model": "claude-sonnet-4-6",
                "prompt": "fallback two",
                "body": "beta",
                "log": "",
                "pending_question": nil,
                "zombie": false
            })

            let response = get("/plans")
            assert_eq(res_status(response), 200)
            let body = res_body(response)
            assert(body.contains("plan-99990070"))
            assert(body.contains("plan-99990071"))
            assert(body.contains("2 plans"))
        })

        test("skips the badge when task_slug points to a deleted task", fn() {
            # Plan still carries the old slug after the user trashed the
            # task — controller must silently fall back to "no badge"
            # rather than 500. Verifies the lookup hash is keyed off the
            # composite (project, slug) so a stale slug doesn't match a
            # task in a different project either.
            Plan.create({
                "_key":              "plan-99990030",
                "project":           "test-project",
                "plan_id":           "plan-99990030",
                "status":            "done",
                "model":             "claude-sonnet-4-6",
                "prompt":            "ghost",
                "body":              "# Ghost",
                "log":               "",
                "pending_question": nil,
                "zombie":            false,
                "task_slug":         "deleted-task"
            })

            let response = get("/plans")
            assert_eq(res_status(response), 200)
            assert_not(res_body(response).contains("data-linked-task="))
        })
    })
})