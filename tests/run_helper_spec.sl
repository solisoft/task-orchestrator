describe("run_helper", fn() {
  describe("task_log_line_class", fn() {
    test("empty line returns h-2", fn() { assert_eq(task_log_line_class(""), "h-2") })

    test("⚙ prefix returns text-slate-500", fn() {
      assert_eq(task_log_line_class("⚙ some log"), "text-slate-500")
    })

    test("▸ prefix returns text-indigo-300", fn() {
      assert_eq(task_log_line_class("▸ doing something"), "text-indigo-300")
    })

    test("💬 prefix returns text-slate-100", fn() {
      assert_eq(task_log_line_class("💬 message"), "text-slate-100")
    })

    test("↩ prefix returns text-slate-400 pl-4", fn() {
      assert_eq(task_log_line_class("↩ some text"), "text-slate-400 pl-4")
    })

    test("- prefix returns text-red-300/90", fn() {
      assert_eq(task_log_line_class("- removed"), "text-red-300/90")
    })

    test("+ prefix returns text-emerald-300/90", fn() {
      assert_eq(task_log_line_class("+ added"), "text-emerald-300/90")
    })

    test(
      "✓ prefix returns text-emerald-300 font-semibold",
      fn() { assert_eq(task_log_line_class("✓ done"), "text-emerald-300 font-semibold") }
    )

    test("FAIL: returns text-red-300", fn() {
      assert_eq(task_log_line_class("FAIL: something bad"), "text-red-300")
    })

    test("failed: in text returns text-red-300", fn() {
      assert_eq(task_log_line_class("something failed: error"), "text-red-300")
    })

    test(
      "[ prefix returns text-slate-500 (ISO timestamp)",
      fn() { assert_eq(task_log_line_class("[2026-05-13T10:30:00Z] log entry"), "text-slate-500") }
    )

    test("default returns text-slate-300", fn() {
      assert_eq(task_log_line_class("some random text"), "text-slate-300")
    })
  })

  describe("task_status_pill", fn() {
    test("nil status returns no run yet", fn() {
      result = task_status_pill(nil)
      assert_eq(result["icon"], "·")
      assert_eq(result["label"], "no run yet")
      assert_eq(result["tone"], "slate")
    })

    test("done: prefix returns emerald", fn() {
      result = task_status_pill("done:some-commit")
      assert_eq(result["icon"], "✓")
      assert_eq(result["label"], "Done")
      assert_eq(result["tone"], "emerald")
    })

    test("failed: prefix returns red with reason", fn() {
      result = task_status_pill("failed:out-of-memory")
      assert_eq(result["icon"], "✗")
      assert_eq(result["label"], "Failed — out-of-memory")
      assert_eq(result["tone"], "red")
    })

    test("starting returns amber", fn() {
      result = task_status_pill("starting")
      assert_eq(result["icon"], "•")
      assert_eq(result["label"], "Starting")
      assert_eq(result["tone"], "amber")
    })

    test("/do-task in status returns amber", fn() {
      result = task_status_pill("running /do-task")
      assert_eq(result["icon"], "▸")
      assert_eq(result["label"], "Running /do-task")
      assert_eq(result["tone"], "amber")
    })

    test("/review-task in status returns amber", fn() {
      result = task_status_pill("running /review-task")
      assert_eq(result["icon"], "▸")
      assert_eq(result["label"], "Running /review-task")
      assert_eq(result["tone"], "amber")
    })

    test("worktree in status returns amber", fn() {
      result = task_status_pill("preparing worktree")
      assert_eq(result["icon"], "▸")
      assert_eq(result["label"], "Preparing worktree")
      assert_eq(result["tone"], "amber")
    })

    test("PR in status returns amber", fn() {
      result = task_status_pill("checking PR status")
      assert_eq(result["icon"], "▸")
      assert_eq(result["tone"], "amber")
    })

    test("pushing in status returns amber", fn() {
      result = task_status_pill("pushing changes")
      assert_eq(result["icon"], "▸")
      assert_eq(result["tone"], "amber")
    })

    test("unknown status returns amber default", fn() {
      result = task_status_pill("unknown-status")
      assert_eq(result["icon"], "•")
      assert_eq(result["tone"], "amber")
    })
  })

  describe("task_status_pill_classes", fn() {
    test("emerald tone returns correct classes", fn() {
      assert_eq(task_status_pill_classes("emerald"), "bg-emerald-400/15 text-emerald-300 border-emerald-400/30")
    })

    test("red tone returns correct classes", fn() {
      assert_eq(task_status_pill_classes("red"), "bg-red-500/15 text-red-300 border-red-500/30")
    })

    test("amber tone returns correct classes", fn() {
      assert_eq(task_status_pill_classes("amber"), "bg-amber-400/15 text-amber-300 border-amber-400/30")
    })

    test("unknown tone returns slate classes", fn() {
      assert_eq(task_status_pill_classes("unknown"), "bg-slate-700/40 text-slate-300 border-slate-600/40")
    })
  })

  describe("task_todo_chrome", fn() {
    test("completed returns correct icon and classes", fn() {
      result = task_todo_chrome("completed")
      assert_eq(result["icon"], "✓")
      assert(result["classes"].contains("line-through"))
    })

    test("in_progress returns correct icon", fn() {
      result = task_todo_chrome("in_progress")
      assert_eq(result["icon"], "▸")
      assert(result["classes"].contains("font-medium"))
    })

    test("cancelled returns correct icon", fn() {
      result = task_todo_chrome("cancelled")
      assert_eq(result["icon"], "✗")
      assert(result["classes"].contains("line-through"))
    })

    test("unknown status returns pending styling", fn() {
      result = task_todo_chrome("unknown")
      assert_eq(result["icon"], "○")
      assert(result["classes"].contains("text-slate-400"))
    })

    test("nil status returns pending styling", fn() {
      result = task_todo_chrome(nil)
      assert_eq(result["icon"], "○")
    })
  })
})
