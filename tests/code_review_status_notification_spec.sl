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

const _crn_log      = "/tmp/_task_orch_web_push.log"
const _crn_sentinel = "/tmp/_task_orch_web_push.active"

def _crn_count_my_lines()
  if not Trusted.exists(_crn_log)
    return 0
  end
  let body = (Trusted.read(_crn_log) rescue "").trim()
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
    if url.starts_with("/projects/crn/")
      n = n + 1
    end
  end
  return n
end

def _crn_my_payloads()
  let out = []
  if not Trusted.exists(_crn_log)
    return out
  end
  let body = (Trusted.read(_crn_log) rescue "").trim()
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
    if url.starts_with("/projects/crn/")
      out.push(payload)
    end
  end
  return out
end

def _crn_seed_review(review_id, slug, status)
  CodeReview.create({
    "_key":      "crn--" + slug + "--" + review_id,
    "project":   "crn",
    "slug":      slug,
    "review_id": review_id,
    "status":    status
  })
end

def _crn_reset()
  for r in CodeReview.where({ "project": "crn" }).all()
    CodeReview.delete(r._key) rescue null
  end
  Trusted.delete(_crn_log) rescue null
  Trusted.write(_crn_sentinel, "1")
end

describe("CodeReview status-change notification", fn()
  before_each(fn()
    assert_test_db()
    _crn_reset()
  end)

  test("does NOT notify on brand-new review creation", fn()
    _crn_seed_review("rev-1", "SEC-100", "starting")
    assert_eq(_crn_count_my_lines(), 0)
  end)

  test("notifies exactly once on append_status transition", fn()
    _crn_seed_review("rev-flip", "SEC-200", "starting")
    CodeReview.append_status("rev-flip", "done")
    assert_eq(_crn_count_my_lines(), 1)
  end)

  test("does NOT notify when append_log does not change status", fn()
    _crn_seed_review("rev-log", "SEC-300", "starting")
    CodeReview.append_log("rev-log", "some log text")
    assert_eq(_crn_count_my_lines(), 0)
  end)

  test("dispatched payload carries title, new status, and click-through URL", fn()
    _crn_seed_review("rev-payload", "SEC-400", "starting")
    CodeReview.append_status("rev-payload", "done")
    let payloads = _crn_my_payloads()
    assert_eq(payloads.length(), 1)
    let payload = payloads[0]
    assert_eq(payload["status"], "done")
    assert_eq(payload["url"], "/projects/crn/tasks/SEC-400")
    assert_eq(payload["title"], "Code Review: SEC-400")
  end)

  test("notifies on every distinct transition (starting → done → failed)", fn()
    _crn_seed_review("rev-multi", "SEC-500", "starting")
    CodeReview.append_status("rev-multi", "done")
    CodeReview.append_status("rev-multi", "failed:reason")
    assert_eq(_crn_count_my_lines(), 2)
  end)
end)
