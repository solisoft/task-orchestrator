# CodeReview status-change notification — `before_save` hook fires a
# Web Push when `status` differs from the previously-persisted value.
# Covers:
#   - brand-new code review creation does NOT notify
#   - append_status transitions DO notify (exactly once)
#   - append_log (no status change) does NOT notify
#   - the dispatched payload carries title + new status + click URL
#
# Mocking: same filesystem-sentinel pattern as task_status_notification_spec.
# Counts are filtered by project name (`crn`) since other specs run
# concurrently against the same log file.
const _crn_log = "/tmp/_task_orch_web_push.log"
const _crn_sentinel = "/tmp/_task_orch_web_push.active"

fn _crn_count_my_lines
  return 0 if !Trusted.exists(_crn_log)
  body = (Trusted.read(_crn_log) rescue "").trim()
  return 0 if body == ""
  n = 0
  for line in body.split("\n")
    next if line == ""
    entry = JSON.parse(line) rescue nil
    next if entry.nil?
    payload = entry["payload"] ?? {}
    url = (payload["url"] ?? "")
    n = n + 1 if url.starts_with("/projects/crn/")
  end
  return n
end

fn _crn_my_payloads
  out = []
  return out if !Trusted.exists(_crn_log)
  body = (Trusted.read(_crn_log) rescue "").trim()
  return out if body == ""
  for line in body.split("\n")
    next if line == ""
    entry = JSON.parse(line) rescue nil
    next if entry.nil?
    payload = entry["payload"] ?? {}
    url = (payload["url"] ?? "")
    out.push(payload) if url.starts_with("/projects/crn/")
  end
  return out
end

fn _crn_seed_review(review_id, slug, status)
  CodeReview.create({
    "project": "crn",
    "slug": slug,
    "review_id": review_id,
    "status": status
  }, {"key": "crn--" + slug + "--" + review_id})
end

fn _crn_reset
  for r in CodeReview.where({"project": "crn"}).all()
    CodeReview.delete(r._key) rescue null
  end
  Trusted.delete(_crn_log) rescue null
  Trusted.write(_crn_sentinel, "1")
end

describe("CodeReview status-change notification", fn() {
  before_each(fn() {
    assert_test_db()
    _crn_reset()
  })

  test("does NOT notify on brand-new review creation", fn() {
    _crn_seed_review("rev-1", "SEC-100", "starting")
    assert_eq(_crn_count_my_lines(), 0)
  })

  test(
    "notifies exactly once on append_status transition",
    fn() {
      _crn_seed_review("rev-flip", "SEC-200", "starting")
      CodeReview.append_status("rev-flip", "done")
      assert_eq(_crn_count_my_lines(), 1)
    }
  )

  test(
    "does NOT notify when append_log does not change status",
    fn() {
      _crn_seed_review("rev-log", "SEC-300", "starting")
      CodeReview.append_log("rev-log", "some log text")
      assert_eq(_crn_count_my_lines(), 0)
    }
  )

  test(
    "dispatched payload carries title, new status, and click-through URL",
    fn() {
      _crn_seed_review("rev-payload", "SEC-400", "starting")
      CodeReview.append_status("rev-payload", "done")
      payloads = _crn_my_payloads()
      assert_eq(payloads.length(), 1)
      payload = payloads[0]
      assert_eq(payload["status"], "done")
      assert_eq(payload["url"], "/projects/crn/tasks/SEC-400")
      assert_eq(payload["title"], "Code Review: SEC-400")
    }
  )

  test(
    "notifies on every distinct transition (starting → done → failed)",
    fn() {
      _crn_seed_review("rev-multi", "SEC-500", "starting")
      CodeReview.append_status("rev-multi", "done")
      CodeReview.append_status("rev-multi", "failed:reason")
      assert_eq(_crn_count_my_lines(), 2)
    }
  )
})
