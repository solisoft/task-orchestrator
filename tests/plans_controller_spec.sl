# Plans controller — lists plans from the solidb `plans` collection.

describe("PlansController", fn() {
    before_each(fn() {
        as_guest()
        assert_test_db()
        Plan.delete_all()
    })

    describe("GET /plans", fn() {
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
    })
})