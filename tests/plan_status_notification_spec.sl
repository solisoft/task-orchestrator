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
const _psn_log = "/tmp/_task_orch_web_push.log"
const _psn_sentinel = "/tmp/_task_orch_web_push.active"

fn _psn_count_my_lines
  return 0 if !Trusted.exists(_psn_log)
  body = (Trusted.read(_psn_log) rescue "").trim()
  return 0 if body == ""
  n = 0
  for line in body.split("\n")
    next if line == ""
    entry = JSON.parse(line) rescue nil
    next if entry.nil?
    payload = entry["payload"] ?? {}
    url = (payload["url"] ?? "")
    n = n + 1 if url.starts_with("/projects/psn/") || url == "/projects/psn"
  end
  return n
end

fn _psn_my_payloads
  out = []
  return out if !Trusted.exists(_psn_log)
  body = (Trusted.read(_psn_log) rescue "").trim()
  return out if body == ""
  for line in body.split("\n")
    next if line == ""
    entry = JSON.parse(line) rescue nil
    next if entry.nil?
    payload = entry["payload"] ?? {}
    url = (payload["url"] ?? "")
    out.push(payload) if url.starts_with("/projects/psn/") || url == "/projects/psn"
  end
  return out
end

fn _psn_seed_plan(plan_id, status)
  Plan.create({
    "project": "psn",
    "plan_id": plan_id,
    "status": status,
    "prompt": "prompt for " + plan_id
  }, {"key": "psn--" + plan_id})
end

fn _psn_reset
  for p in Plan.where({"project": "psn"}).all()
    Plan.delete(p._key) rescue null
  end
  Trusted.delete(_psn_log) rescue null
  Trusted.write(_psn_sentinel, "1")
end

describe("Plan status-change notification", fn() {
  before_each(fn() {
    assert_test_db()
    _psn_reset()
  })

  test("does NOT notify on brand-new plan creation", fn() {
    _psn_seed_plan("first", "starting")
    assert_eq(_psn_count_my_lines(), 0)
  })

  test(
    "notifies exactly once on append_status transition",
    fn() {
      _psn_seed_plan("flip", "starting")
      Plan.append_status("psn--flip", "done")
      assert_eq(_psn_count_my_lines(), 1)
    }
  )

  test(
    "does NOT notify when append_log does not change status",
    fn() {
      _psn_seed_plan("logonly", "starting")
      Plan.append_log("psn--logonly", "some log text")
      assert_eq(_psn_count_my_lines(), 0)
    }
  )

  test(
    "dispatched payload carries title, new status, and URL",
    fn() {
      _psn_seed_plan("payload", "starting")
      Plan.append_status("psn--payload", "done")
      payloads = _psn_my_payloads()
      assert_eq(payloads.length(), 1)
      payload = payloads[0]
      assert_eq(payload["status"], "done")
      assert_eq(payload["url"], "/projects/psn")
      assert_eq(payload["title"], "prompt for payload")
    }
  )

  test(
    "notifies on every distinct transition (starting → done → failed)",
    fn() {
      _psn_seed_plan("multi", "starting")
      Plan.append_status("psn--multi", "done")
      Plan.append_status("psn--multi", "failed:reason")
      assert_eq(_psn_count_my_lines(), 2)
    }
  )

  test("URL links to task when task_slug is set", fn() {
    Plan.create({
      "project": "psn",
      "plan_id": "with-task",
      "status": "starting",
      "task_slug": "SEC-100",
      "prompt": "prompt with task"
    }, {"key": "psn--with-task"})
    Plan.append_status("psn--with-task", "done")
    payloads = _psn_my_payloads()
    assert_eq(payloads.length(), 1)
    assert_eq(payloads[0]["url"], "/projects/psn/tasks/SEC-100")
  })

  test(
    "URL links to feature when feature_slug is set and task_slug is not",
    fn() {
      Plan.create({
        "project": "psn",
        "plan_id": "with-feat",
        "status": "starting",
        "feature_slug": "feat-42",
        "prompt": "prompt with feature"
      }, {"key": "psn--with-feat"})
      Plan.append_status("psn--with-feat", "done")
      payloads = _psn_my_payloads()
      assert_eq(payloads.length(), 1)
      assert_eq(payloads[0]["url"], "/projects/psn/features/feat-42")
    }
  )
})
