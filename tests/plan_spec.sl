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

describe("Plan.allow_plan_model / _is_codex_model_id", fn() {
    before_each(fn() {
        assert_test_db()
    })

    test("allow_plan_model accepts a valid codex model id", fn() {
        assert_eq(Plan.allow_plan_model("codex/gpt-4o"), "codex/gpt-4o")
    })

    test("allow_plan_model accepts a codex model with dots and dashes", fn() {
        assert_eq(Plan.allow_plan_model("codex/gpt-4.1-mini"), "codex/gpt-4.1-mini")
    })

    test("allow_plan_model rejects bare model without codex/ prefix", fn() {
        assert_eq(Plan.allow_plan_model("gpt-4o"), "claude-sonnet-4-6")
    })

    test("allow_plan_model rejects codex/ with empty model", fn() {
        assert_eq(Plan.allow_plan_model("codex/"), "claude-sonnet-4-6")
    })

    test("allow_plan_model still accepts Claude SDK ids", fn() {
        assert_eq(Plan.allow_plan_model("claude-opus-4-7"), "claude-opus-4-7")
    })

    test("allow_plan_model still accepts opencode provider/model ids", fn() {
        assert_eq(Plan.allow_plan_model("deepseek/deepseek-chat"), "deepseek/deepseek-chat")
    })

    test("_is_codex_model_id returns false for empty strings", fn() {
        assert_not(Plan._is_codex_model_id(""))
    })

    test("_is_codex_model_id returns false for short strings", fn() {
        assert_not(Plan._is_codex_model_id("codex"))
    })

    test("_is_codex_model_id returns false for non-codex models", fn() {
        assert_not(Plan._is_codex_model_id("claude-opus-4-7"))
    })

    test("_is_codex_model_id returns true for valid codex models", fn() {
        assert(Plan._is_codex_model_id("codex/gpt-4o"))
        assert(Plan._is_codex_model_id("codex/o3-mini"))
        assert(Plan._is_codex_model_id("codex/gpt-4.1-nano"))
    })
})

describe("Plan.default_plan_model", fn() {
    before_each(fn() {
        assert_test_db()
        Setting.delete_all()
    })

    test("returns claude-sonnet-4-6 when nothing is persisted", fn() {
        assert_eq(Plan.default_plan_model(), "claude-sonnet-4-6")
    })

    test("returns the persisted plan_model", fn() {
        Setting.set("plan_model", "claude-opus-4-7")
        assert_eq(Plan.default_plan_model(), "claude-opus-4-7")
    })
})

describe("Plan.default_review_model", fn() {
    before_each(fn() {
        assert_test_db()
        Setting.delete_all()
    })

    test("returns claude-haiku-4-5-20251001 when nothing is persisted", fn() {
        assert_eq(Plan.default_review_model(), "claude-haiku-4-5-20251001")
    })

    test("returns the persisted review_model", fn() {
        Setting.set("review_model", "claude-sonnet-4-6")
        assert_eq(Plan.default_review_model(), "claude-sonnet-4-6")
    })
})

describe("Plan.allowed_model_ids", fn() {
    before_each(fn() {
        assert_test_db()
        Setting.delete_all()
    })

    test("returns empty list when nothing is persisted", fn() {
        assert_eq(Plan.allowed_model_ids().length(), 0)
    })

    test("returns the persisted allowlist", fn() {
        Setting.set("allowed_models", ["claude-opus-4-7", "codex/gpt-4o"])
        let ids = Plan.allowed_model_ids()
        assert_eq(ids.length(), 2)
        assert(ids.contains("claude-opus-4-7"))
        assert(ids.contains("codex/gpt-4o"))
    })
})

describe("Plan.is_allowed_model", fn() {
    before_each(fn() {
        assert_test_db()
        Setting.delete_all()
    })

    test("returns true when allowlist is empty (no filter)", fn() {
        Setting.set("allowed_models", [])
        assert(Plan.is_allowed_model("claude-opus-4-7"))
    })

    test("returns true when id is on the allowlist", fn() {
        Setting.set("allowed_models", ["claude-opus-4-7"])
        assert(Plan.is_allowed_model("claude-opus-4-7"))
    })

    test("returns false when id is not on the allowlist", fn() {
        Setting.set("allowed_models", ["claude-opus-4-7"])
        assert_not(Plan.is_allowed_model("codex/gpt-4o"))
    })
})

describe("Plan.claude_model_ids / claude_model_labels", fn() {
    test("claude_model_ids returns the expected list", fn() {
        let ids = Plan.claude_model_ids()
        assert(ids.contains("claude-opus-4-7"))
        assert(ids.contains("claude-sonnet-4-6"))
        assert_eq(ids.length(), 3)
    })

    test("claude_model_labels maps every id to a friendly label", fn() {
        let labels = Plan.claude_model_labels()
        for id in Plan.claude_model_ids()
            assert_hash_has_key(labels, id)
        end
    })
})

describe("Plan.filter_allowed", fn() {
    before_each(fn() {
        assert_test_db()
        Setting.delete_all()
    })

    test("passes through when allowlist is empty", fn() {
        let ids = ["claude-opus-4-7", "claude-haiku-4-5-20251001"]
        assert_eq(Plan.filter_allowed(ids, ""), ids)
    })

    test("filters to only allowlisted ids", fn() {
        Setting.set("allowed_models", ["claude-opus-4-7"])
        let ids = ["claude-opus-4-7", "claude-haiku-4-5-20251001"]
        let filtered = Plan.filter_allowed(ids, "")
        assert_eq(filtered.length(), 1)
        assert_eq(filtered[0], "claude-opus-4-7")
    })

    test("always keeps the current selection even if outside allowlist", fn() {
        Setting.set("allowed_models", ["claude-opus-4-7"])
        let ids = ["claude-opus-4-7", "claude-haiku-4-5-20251001"]
        let filtered = Plan.filter_allowed(ids, "claude-haiku-4-5-20251001")
        assert(filtered.contains("claude-haiku-4-5-20251001"))
    })
})
