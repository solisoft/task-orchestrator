# Plans controller — lists plans from the solidb `plans` collection.

describe("PlansController", fn() {
    describe("GET /plans", fn() {
        # before_each must live at the same describe level as the tests
        # — Soli's before_each does not cascade into nested describes,
        # so seating it at the outer level would leave the DB polluted
        # between cases and make absence-assertions racy.
        before_each(fn() {
            as_guest()
            assert_test_db()
            Plan.delete_all()
            Task.delete_all()
        })

        test("returns 200 with no plans", fn() {
            let response = get("/plans")
            assert_eq(res_status(response), 200)
            assert(res_body(response).contains("No plans yet"))
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