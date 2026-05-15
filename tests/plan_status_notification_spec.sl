# Plan status-change notification — `before_save` hook fires a Web
# Push when `status` differs from the previously-persisted value.
# Covers:
#   - brand-new plan creation does NOT notify
#   - append_status transitions DO notify (exactly once)
#   - append_log (no status change) does NOT notify
#   - the dispatched payload carries title + new status + click URL
#   - notification URL links to associated task when task_slug is set
#   - notification URL links to associated feature when feature_slug is set
#   - notification URL falls back to plans index when neither is set
#
# Mocking: same filesystem-sentinel pattern as task_status_notification_spec.
# Counts are filtered by project name (`psn`) since other specs run
# concurrently against the same log file.

const _psn_log      = "/tmp/_task_orch_web_push.log"
const _psn_sentinel = "/tmp/_task_orch_web_push.active"

def _psn_count_my_lines()
  if not Trusted.exists(_psn_log)
    return 0
  end
  let body = (Trusted.read(_psn_log) rescue "").trim()
  if body == ""
    return 0
  end
  let n = 0
  for line in body.split("\n")
    if line == ""
      next
    end
    let entry = JSON.parse(line) rescue nil
    if entry == nil
      next
    end
    let payload = entry["payload"] ?? {}
    let url = (payload["url"] ?? "")
    if url.starts_with("/projects/psn/")
      n = n + 1
    end
  end
  return n
end

def _psn_my_payloads()
  let out = []
  if not Trusted.exists(_psn_log)
    return out
  end
  let body = (Trusted.read(_psn_log) rescue "").trim()
  if body == ""
    return out
  end
  for line in body.split("\n")
    if line == ""
      next
    end
    let entry = JSON.parse(line) rescue nil
    if entry == nil
      next
    end
    let payload = entry["payload"] ?? {}
    let url = (payload["url"] ?? "")
    if url.starts_with("/projects/psn/")
      out.push(payload)
    end
  end
  return out
end

def _psn_seed_plan(plan_id, status)
  Plan.create({
    "_key":    "psn--" + plan_id,
    "project": "psn",
    "plan_id": plan_id,
    "status":  status,
    "prompt":  "prompt for " + plan_id
  })
end

def _psn_reset()
  for p in Plan.where({ "project": "psn" }).all()
    Plan.delete(p._key) rescue null
  end
  Trusted.delete(_psn_log) rescue null
  Trusted.write(_psn_sentinel, "1")
end

describe("Plan status-change notification", fn()
  before_each(fn()
    assert_test_db()
    _psn_reset()
  end)

  test("does NOT notify on brand-new plan creation", fn()
    _psn_seed_plan("first", "starting")
    assert_eq(_psn_count_my_lines(), 0)
  end)

  test("notifies exactly once on append_status transition", fn()
    _psn_seed_plan("flip", "starting")
    Plan.append_status("psn--flip", "done")
    assert_eq(_psn_count_my_lines(), 1)
  end)

  test("does NOT notify when append_log does not change status", fn()
    _psn_seed_plan("logonly", "starting")
    Plan.append_log("psn--logonly", "some log text")
    assert_eq(_psn_count_my_lines(), 0)
  end)

  test("dispatched payload carries title, new status, and URL", fn()
    _psn_seed_plan("payload", "starting")
    Plan.append_status("psn--payload", "done")
    let payloads = _psn_my_payloads()
    assert_eq(payloads.length(), 1)
    let payload = payloads[0]
    assert_eq(payload["status"], "done")
    assert_eq(payload["url"], "/projects/psn/plans")
    assert_eq(payload["title"], "prompt for payload")
  end)

  test("notifies on every distinct transition (starting → done → failed)", fn()
    _psn_seed_plan("multi", "starting")
    Plan.append_status("psn--multi", "done")
    Plan.append_status("psn--multi", "failed:reason")
    assert_eq(_psn_count_my_lines(), 2)
  end)

  test("URL links to task when task_slug is set", fn()
    Plan.create({
      "_key":       "psn--with-task",
      "project":    "psn",
      "plan_id":    "with-task",
      "status":     "starting",
      "task_slug":  "SEC-100",
      "prompt":     "prompt with task"
    })
    Plan.append_status("psn--with-task", "done")
    let payloads = _psn_my_payloads()
    assert_eq(payloads.length(), 1)
    assert_eq(payloads[0]["url"], "/projects/psn/tasks/SEC-100")
  end)

  test("URL links to feature when feature_slug is set and task_slug is not", fn()
    Plan.create({
      "_key":         "psn--with-feat",
      "project":      "psn",
      "plan_id":      "with-feat",
      "status":       "starting",
      "feature_slug": "feat-42",
      "prompt":       "prompt with feature"
    })
    Plan.append_status("psn--with-feat", "done")
    let payloads = _psn_my_payloads()
    assert_eq(payloads.length(), 1)
    assert_eq(payloads[0]["url"], "/projects/psn/features/feat-42")
  end)
end)
