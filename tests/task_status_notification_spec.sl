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
const _tsn_log = "/tmp/_task_orch_web_push.log"
const _tsn_sentinel = "/tmp/_task_orch_web_push.active"

fn _tsn_count_my_lines
  return 0 if !Trusted.exists(_tsn_log)
  body = (Trusted.read(_tsn_log) rescue "").trim()
  return 0 if body == ""
  n = 0
  for line in body.split("\n")
    next if line == ""
    entry = JSON.parse(line) rescue nil
    next if entry.nil?
    payload = entry["payload"] ?? {}
    url = (payload["url"] ?? "")
    n = n + 1 if url.starts_with("/projects/tsn/")
  end
  return n
end

fn _tsn_my_payloads
  out = []
  return out if !Trusted.exists(_tsn_log)
  body = (Trusted.read(_tsn_log) rescue "").trim()
  return out if body == ""
  for line in body.split("\n")
    next if line == ""
    entry = JSON.parse(line) rescue nil
    next if entry.nil?
    payload = entry["payload"] ?? {}
    url = (payload["url"] ?? "")
    out.push(payload) if url.starts_with("/projects/tsn/")
  end
  return out
end

fn _tsn_seed_task(slug, status)
  Task.create({
    "project": "tsn",
    "slug": slug,
    "title": "title for " + slug,
    "status": status
  }, {"key": "tsn--" + slug})
end

fn _tsn_reset

  # Wipe only the `tsn` project's tasks so we don't disturb tasks that
  # other specs are mid-flight on (Task.delete_all() would).
  for t in Task.where({"project": "tsn"}).all()
    Task.delete(t._key) rescue null
  end
  Trusted.delete(_tsn_log) rescue null
  Trusted.write(_tsn_sentinel, "1")
end

describe("Task status-change notification", fn() {
  before_each(fn() {
    assert_test_db()
    _tsn_reset()
  })

  test("does NOT notify on brand-new task creation", fn() {
    _tsn_seed_task("first", "todo")
    assert_eq(_tsn_count_my_lines(), 0)
  })

  test("notifies exactly once on a status transition", fn() {
    _tsn_seed_task("flip", "todo")
    t = Task.find_by_slug("tsn", "flip")
    t.status = "queued"
    t.save()
    assert_eq(_tsn_count_my_lines(), 1)
  })

  test(
    "does NOT notify when save() does not change status",
    fn() {
      _tsn_seed_task("notitle", "todo")
      t = Task.find_by_slug("tsn", "notitle")
      t.title = "new title — same status"
      t.save()
      assert_eq(_tsn_count_my_lines(), 0)
    }
  )

  test(
    "dispatched payload carries title, new status, and click-through URL",
    fn() {
      _tsn_seed_task("payload", "todo")
      t = Task.find_by_slug("tsn", "payload")
      t.status = "review"
      t.save()
      payloads = _tsn_my_payloads()
      assert_eq(payloads.length(), 1)
      payload = payloads[0]
      assert_eq(payload["status"], "review")
      assert_eq(payload["url"], "/projects/tsn/tasks/payload")
      assert_eq(payload["title"], "title for payload")
    }
  )

  test(
    "notifies on every distinct transition (todo → queued → inprogress)",
    fn() {
      _tsn_seed_task("multi", "todo")
      t = Task.find_by_slug("tsn", "multi")
      t.status = "queued"
      t.save()
      t2 = Task.find_by_slug("tsn", "multi")
      t2.status = "inprogress"
      t2.save()
      assert_eq(_tsn_count_my_lines(), 2)
    }
  )
})
