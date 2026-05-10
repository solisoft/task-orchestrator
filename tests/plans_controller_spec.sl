# Plans controller — lists agent-drafted task specs from
# run_state_root()/_plans/.

describe("PlansController", fn() {
  before_each(fn() {
    as_guest()
    let root = getenv("TASK_ORCH_STATE") ?? "/tmp/task-orch-spec-state"
    System.run_sync(["rm", "-rf", root + "/_plans"])
  })

  describe("GET /plans", fn() {
    test("returns 200 with no plans", fn() {
      let response = get("/plans")
      assert_eq(res_status(response), 200)
      assert(res_body(response).contains("No plans yet"))
    })

    test("lists a done plan with rendered body", fn() {
      _plan_fixture("plan-99990001", "done",
        "claude-sonnet-4-6", "add a footer",
        "# Fix pagination\n\n## Severity\nhigh")

      let response = get("/plans")
      assert_eq(res_status(response), 200)
      let body = res_body(response)
      assert(body.contains("plan-99990001"))
      assert(body.contains("claude-sonnet-4-6"))
      assert(body.contains("Fix pagination"))
    })

    test("lists a failed plan", fn() {
      _plan_fixture("plan-99990002", "failed:rc=1",
        "claude-opus-4-7", "broken", "")

      let response = get("/plans")
      assert_eq(res_status(response), 200)
      assert(res_body(response).contains("plan-99990002"))
    })

    test("sorts plans newest-first by id", fn() {
      for i in [1, 2, 3]
        _plan_fixture("plan-9999000" + str(i), "done",
          "claude-sonnet-4-6", "test " + str(i),
          "# Task " + str(i))
      end

      let body = res_body(get("/plans"))
      let p1 = body.index_of("plan-99990003")
      let p2 = body.index_of("plan-99990002")
      let p3 = body.index_of("plan-99990001")
      assert(p1 != -1 and p2 != -1 and p3 != -1 and p1 < p2 and p2 < p3)
    })

    test("reading state for a missing plan dir does not crash", fn() {
      let response = get("/plans")
      assert_eq(res_status(response), 200)
    })
  })
})

def _plan_fixture(id, status, model, prompt, body)
  let root = getenv("TASK_ORCH_STATE") ?? "/tmp/task-orch-spec-state"
  let dir = root + "/_plans/" + id
  System.run_sync(["mkdir", "-p", dir])
  let ts = "2026-05-10T12:00:00+00:00"
  Trusted.write(dir + "/status", ts + "\t" + status + "\n")
  Trusted.write(dir + "/model", model + "\n")
  Trusted.write(dir + "/prompt", prompt + "\n")
  if body != ""
    Trusted.write(dir + "/body", body + "\n")
  end
end
