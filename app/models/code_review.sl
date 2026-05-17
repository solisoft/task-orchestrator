# CodeReview — one row per `bin/review-run` invocation kicked off from
# the task show page's code-review panel.
#
# Identity: `_key` = `<project>--<slug>--<review_id>`; `review_id` is
# stable across the lifetime of the row and is what `bin/review-run`
# uses to look up its own row when it writes log / status / body back.

class CodeReview < Model
  validates("project",   { "presence": true })
  validates("slug",      { "presence": true })
  validates("review_id", { "presence": true })

  before_save("touch_timestamps")

  static def key_for(project, slug, review_id)
    project + "--" + slug + "--" + review_id
  end

  static def find_by_review_id(review_id)
    CodeReview.find_by("review_id", review_id)
  end

  # All reviews for a given task, newest first. Used by the panel to
  # render the history list.
  static def for_task(project, slug)
    CodeReview.where({ "project": project, "slug": slug })
              .order("review_id", "desc")
              .all()
  end

  # Append to the log column atomically — bin/review-run writes one
  # rendered line at a time, mirroring Plan.append_log.
  static def append_log(review_id, text)
    row = CodeReview.find_by_review_id(review_id)
    if row != nil
      row.log = (row.log ?? "") + text
      row.save()
    end
  end

  static def append_status(review_id, status)
    row = CodeReview.find_by_review_id(review_id)
    if row != nil
      row.status = status
      row.updated_at = DateTime.now().to_iso()
      row.save()
    end
  end

  # Liveness probe — same shape as Plan.effective_status so the WS
  # handler can flip a stuck `starting`/`running` row to `failed:zombie`
  # when the runner is gone and the heartbeat is stale.
  def effective_status()
    s = self.status ?? ""
    if s == "done" or s.starts_with("failed:")
      return s
    end
    alive = CodeReview._pid_alive(self.pid)
    if alive == false
      return "failed:zombie (no live process)"
    end
    if alive == nil
      age = self._stale_seconds()
      if age != nil and age > 600
        return "failed:zombie (no heartbeat for " + str(age / 60) + "m)"
      end
    end
    s
  end

  static def _pid_alive(pid)
    if pid == nil
      return nil
    end
    res = System.run_sync(["kill", "-0", str(pid)]) rescue { "exit_code": 1 }
    res["exit_code"] == 0
  end

  def _stale_seconds()
    if self.updated_at == nil or self.updated_at == ""
      return nil
    end
    prior = DateTime.parse(self.updated_at).to_unix() rescue nil
    if prior == nil
      return nil
    end
    DateTime.now().to_unix() - prior
  end

  def _notify_if_status_changed()
    if self._key == nil or self._key == ""
      return nil
    end
    new_status = self.status ?? ""
    if self.last_notified_status == new_status
      return nil
    end
    prev = CodeReview.find_by("_key", self._key) rescue nil
    if prev == nil
      return nil
    end
    prev_status = prev.status ?? ""
    if prev_status == new_status
      return nil
    end
    self.last_notified_status = new_status
    title = "Code Review: " + (self.slug ?? "")
    url = "/projects/" + (self.project ?? "") + "/tasks/" + (self.slug ?? "")
    web_push_send_to_all({
      "title":  title,
      "status": new_status,
      "url":    url
    }) rescue null
  end

  def verdict()
    b = self.body ?? ""
    if b == ""
      return nil
    end
    marker = "**Verdict:**"
    parts = b.split(marker)
    if parts.length() < 2
      plain_parts = b.split("Verdict:")
      if plain_parts.length() < 2
        return nil
      end
      raw = plain_parts[1].split("\n")[0].trim()
      words = raw.split(" ")
      if words.length() > 0 and words[0].length() > 0
        return words[0].replace("**", "")
      end
      return nil
    end
    line = parts[1].split("\n")[0].trim()
    words = line.split(" ")
    if words.length() > 0 and words[0].length() > 0
      return words[0].replace("**", "")
    end
    nil
  end

  def touch_timestamps()
    now = DateTime.now().to_iso()
    if self.created_at == nil
      self.created_at = now
    end
    self.updated_at = now
    self._notify_if_status_changed()
  end
end

# WS payload builder for the code-review stream. Returns the same
# delta/snapshot shape as plan_stream_payload so the same client
# controller in public/run-stream.js can drive both.
fn code_review_stream_payload(review_id, event_type, offset)
  row = CodeReview.find_by_review_id(review_id)
  if row == nil
    return { "event": "error", "terminal": true, "message": "unknown review" }
  end
  cursor = offset
  if cursor == nil or cursor < 0
    cursor = 0
  end
  log = row.log ?? ""
  size = log.length
  if cursor > size
    cursor = 0
  end
  chunk = ""
  if cursor < size
    chunk = log.substring(cursor, size)
  end
  status_token = row.effective_status
  done = status_token == "done"
  failed = status_token.starts_with("failed:")
  {
    "event":      event_type == "connect" ? "snapshot" : "delta",
    "log_chunk":  chunk,
    "log_offset": size,
    "status":     status_token,
    "terminal":   done or failed,
    "reload":     done or failed
  }
end
