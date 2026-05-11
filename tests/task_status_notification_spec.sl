# Task status-change notification — `before_save` hook fires a Web
# Push when `status` differs from the previously-persisted value.
# Covers:
#   - brand-new task creation does NOT notify
#   - status transitions on existing rows DO notify (exactly once)
#   - a save that doesn't touch status does NOT notify
#   - the dispatched payload carries title + new status + click URL
#
# Mocking: the WebPush helper checks for a filesystem sentinel
# (`/tmp/_task_orch_web_push.active`); when present it appends each
# payload as a JSON line to `/tmp/_task_orch_web_push.log` instead of
# shelling out to the Node CLI. We use a filesystem gate (vs. a
# `Setting` row) because parallel specs run `Setting.delete_all()`
# against the shared test DB.
#
# Counts are filtered by project name (`tsn`) since other specs run
# concurrently against the same log file and would otherwise add
# spurious entries.

const _tsn_log       = "/tmp/_task_orch_web_push.log"
const _tsn_sentinel  = "/tmp/_task_orch_web_push.active"

def _tsn_count_my_lines()
  if not Trusted.exists(_tsn_log)
    return 0
  end
  let body = (Trusted.read(_tsn_log) rescue "").trim()
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
    if url.starts_with("/projects/tsn/")
      n = n + 1
    end
  end
  return n
end

def _tsn_my_payloads()
  let out = []
  if not Trusted.exists(_tsn_log)
    return out
  end
  let body = (Trusted.read(_tsn_log) rescue "").trim()
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
    if url.starts_with("/projects/tsn/")
      out.push(payload)
    end
  end
  return out
end

def _tsn_seed_task(slug, status)
  Task.create({
    "_key":    "tsn--" + slug,
    "project": "tsn",
    "slug":    slug,
    "title":   "title for " + slug,
    "status":  status
  })
end

def _tsn_reset()
  # Wipe only the `tsn` project's tasks so we don't disturb tasks that
  # other specs are mid-flight on (Task.delete_all() would).
  for t in Task.where({ "project": "tsn" }).all()
    Task.delete(t._key) rescue null
  end
  Trusted.delete(_tsn_log) rescue null
  Trusted.write(_tsn_sentinel, "1")
end

describe("Task status-change notification", fn()
  before_each(fn()
    assert_test_db()
    _tsn_reset()
  end)

  test("does NOT notify on brand-new task creation", fn()
    _tsn_seed_task("first", "todo")
    assert_eq(_tsn_count_my_lines(), 0)
  end)

  test("notifies exactly once on a status transition", fn()
    _tsn_seed_task("flip", "todo")
    let t = Task.find_by_slug("tsn", "flip")
    t.status = "queued"
    t.save()
    assert_eq(_tsn_count_my_lines(), 1)
  end)

  test("does NOT notify when save() does not change status", fn()
    _tsn_seed_task("notitle", "todo")
    let t = Task.find_by_slug("tsn", "notitle")
    t.title = "new title — same status"
    t.save()
    assert_eq(_tsn_count_my_lines(), 0)
  end)

  test("dispatched payload carries title, new status, and click-through URL", fn()
    _tsn_seed_task("payload", "todo")
    let t = Task.find_by_slug("tsn", "payload")
    t.status = "review"
    t.save()
    let payloads = _tsn_my_payloads()
    assert_eq(payloads.length(), 1)
    let payload = payloads[0]
    assert_eq(payload["status"], "review")
    assert_eq(payload["url"], "/projects/tsn/tasks/payload")
    assert_eq(payload["title"], "title for payload")
  end)

  test("notifies on every distinct transition (todo → queued → inprogress)", fn()
    _tsn_seed_task("multi", "todo")
    let t = Task.find_by_slug("tsn", "multi")
    t.status = "queued"
    t.save()
    let t2 = Task.find_by_slug("tsn", "multi")
    t2.status = "inprogress"
    t2.save()
    assert_eq(_tsn_count_my_lines(), 2)
  end)
end)
