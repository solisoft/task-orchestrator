# Plan model — zombie detection via effective_status().
#
# `bin/plan-run` writes its PID into the row at startup and clears it on
# clean exit. When the runner is SIGKILLed (OOM, terminal close, reboot)
# the trap doesn't run, the row stays "starting" forever, and the UI
# can't tell the agent is dead. `effective_status()` plugs that gap by
# probing the recorded pid with `kill -0` and synthesizing a `failed:`
# token when the process is gone.

describe("Plan.effective_status", fn() {
    before_each(fn() {
        assert_test_db()
        Plan.delete_all()
    })

    test("returns the raw status for terminal: done", fn() {
        let plan = Plan.create({
            "_key":    "plan-test-done",
            "project": "x",
            "plan_id": "plan-test-done",
            "status":  "done",
            "pid":     nil
        })
        assert_eq(plan.effective_status, "done")
    })

    test("returns the raw status for terminal: failed:*", fn() {
        let plan = Plan.create({
            "_key":    "plan-test-failed",
            "project": "x",
            "plan_id": "plan-test-failed",
            "status":  "failed:rc=1",
            "pid":     nil
        })
        assert_eq(plan.effective_status, "failed:rc=1")
    })

    test("returns starting when pid is live", fn() {
        # Spawn a short backgrounded sleep so we get a stable, live PID
        # for the assertion. The sleep exits on its own — no cleanup
        # kill needed (and `kill` is forbidden by CLAUDE.md anyway).
        # Cannot use `bash -c "echo $$"` — that subprocess exits before
        # the assertion runs.
        let spawn = System.run_sync(["bash", "-c", "nohup sleep 5 >/dev/null 2>&1 & echo $!; disown"])
        let live_pid = spawn["stdout"].trim().to_int()
        let plan = Plan.create({
            "_key":    "plan-test-alive",
            "project": "x",
            "plan_id": "plan-test-alive",
            "status":  "starting",
            "pid":     live_pid
        })
        assert_eq(plan.effective_status, "starting")
    })

    test("synthesizes failed:zombie when pid is dead", fn() {
        # PID 2^31 - 1 is reserved as "no process" on Linux — kill -0
        # against it always returns ESRCH.
        let plan = Plan.create({
            "_key":    "plan-test-zombie",
            "project": "x",
            "plan_id": "plan-test-zombie",
            "status":  "starting",
            "pid":     2147483647
        })
        let s = plan.effective_status
        assert(s.starts_with("failed:zombie"))
    })

    test("falls back to heartbeat when no pid recorded", fn() {
        # No pid + stale updated_at → heartbeat path. Updated_at is set
        # by the touch_timestamps callback to now, so override it after
        # creation (save() refreshes it; bypass via direct AQL).
        let plan = Plan.create({
            "_key":    "plan-test-heartbeat",
            "project": "x",
            "plan_id": "plan-test-heartbeat",
            "status":  "starting",
            "pid":     nil
        })
        plan.updated_at = "2020-01-01T00:00:00Z"
        # touch_timestamps would overwrite updated_at on save(); test the
        # method in isolation against an in-memory mutation.
        assert(plan.effective_status.starts_with("failed:zombie"))
    })

    test("prompt_preview returns the whole prompt under the cap", fn() {
        let plan = Plan.create({
            "_key":    "plan-prev-short",
            "project": "x",
            "plan_id": "plan-prev-short",
            "status":  "done",
            "prompt":  "short prompt"
        })
        assert_eq(plan.prompt_preview(100), "short prompt")
    })

    test("prompt_preview truncates with ellipsis above the cap", fn() {
        let long = ""
        let i = 0
        while i < 120
            long = long + "a"
            i = i + 1
        end
        let plan = Plan.create({
            "_key":    "plan-prev-long",
            "project": "x",
            "plan_id": "plan-prev-long",
            "status":  "done",
            "prompt":  long
        })
        let out = plan.prompt_preview(100)
        # The ellipsis is multi-byte under UTF-8 (Soli .length returns
        # bytes), so check the byte count is 100 'a's + 3 for "…".
        assert_eq(out.length(), 103)
        assert(out.ends_with("…"))
    })

    test("prompt_preview collapses newlines into single line", fn() {
        let plan = Plan.create({
            "_key":    "plan-prev-nl",
            "project": "x",
            "plan_id": "plan-prev-nl",
            "status":  "done",
            "prompt":  "line one\nline two\nline three"
        })
        assert_eq(plan.prompt_preview(100).index_of("\n"), -1)
    })

    test("keeps starting when no pid and updated_at is recent", fn() {
        let plan = Plan.create({
            "_key":    "plan-test-recent",
            "project": "x",
            "plan_id": "plan-test-recent",
            "status":  "starting",
            "pid":     nil
        })
        # touch_timestamps sets updated_at to now on create, so this is
        # well within the 10-minute window.
        assert_eq(plan.effective_status, "starting")
    })
})

describe("plan_stream_payload — model-layer builder for the plan/feature WS frame", fn() {
    before_each(fn() {
        assert_test_db()
        Plan.delete_all()
    })

    test("connect → snapshot returns the entire log as one chunk", fn() {
        let spawn = System.run_sync(["bash", "-c", "nohup sleep 5 >/dev/null 2>&1 & echo $!; disown"])
        let live_pid = spawn["stdout"].trim().to_int()
        Plan.create({
            "_key":    "plan-stream-snap",
            "project": "x",
            "plan_id": "plan-stream-snap",
            "status":  "starting",
            "log":     "boot...\nready\n",
            "pid":     live_pid
        })
        let p = plan_stream_payload("plan-stream-snap", "connect", 0)
        assert_eq(p["event"], "snapshot")
        assert_eq(p["log_chunk"], "boot...\nready\n")
        assert_eq(p["log_offset"], "boot...\nready\n".length)
        assert_eq(p["terminal"], false)
    })

    test("tick → delta only the bytes past the cursor", fn() {
        let spawn = System.run_sync(["bash", "-c", "nohup sleep 5 >/dev/null 2>&1 & echo $!; disown"])
        let live_pid = spawn["stdout"].trim().to_int()
        Plan.create({
            "_key":    "plan-stream-delta",
            "project": "x",
            "plan_id": "plan-stream-delta",
            "status":  "starting",
            "log":     "abcdefghij",
            "pid":     live_pid
        })
        let p = plan_stream_payload("plan-stream-delta", "message", 4)
        assert_eq(p["event"], "delta")
        assert_eq(p["log_chunk"], "efghij")
        assert_eq(p["log_offset"], 10)
    })

    test("flips terminal=true on done", fn() {
        Plan.create({
            "_key":    "plan-stream-done",
            "project": "x",
            "plan_id": "plan-stream-done",
            "status":  "done",
            "log":     "all green\n"
        })
        let p = plan_stream_payload("plan-stream-done", "message", 0)
        assert_eq(p["terminal"], true)
    })

    test("unknown plan returns an error frame", fn() {
        let p = plan_stream_payload("plan-stream-missing", "connect", 0)
        assert_eq(p["event"], "error")
        assert_eq(p["terminal"], true)
    })
})
