# CodeReview — one row per `bin/review-run` invocation kicked off from
# the task show page's code-review panel.
#
# Identity: `_key` = `<project>--<slug>--<review_id>`; `review_id` is
# stable across the lifetime of the row and is what `bin/review-run`
# uses to look up its own row when it writes log / status / body back.
class CodeReview < Model
  validates("project", {"presence": true})
  validates("slug", {"presence": true})
  validates("review_id", {"presence": true})
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
    CodeReview.where({"project": project, "slug": slug}).order("review_id", "desc").all()
  end

  # Append to the log column atomically — bin/review-run writes one
  # rendered line at a time, mirroring Plan.append_log.
  static def append_log(review_id, text)
    row = CodeReview.find_by_review_id(review_id)
    if row.present?
      row.log = (row.log ?? "") + text
      row.save()
    end
  end

  static def append_status(review_id, status)
    row = CodeReview.find_by_review_id(review_id)
    if row.present?
      row.status = status
      row.updated_at = DateTime.now().to_iso()
      row.save()
    end
  end

  # Liveness probe — same shape as Plan.effective_status so the WS
  # handler can flip a stuck `starting`/`running` row to `failed:zombie`
  # when the runner is gone and the heartbeat is stale.
  def effective_status()
    s = this.status ?? ""
    return s if s == "done" || s.starts_with("failed:")
    alive = CodeReview._pid_alive(this.pid)
    return "failed:zombie (no live process)" if alive == false
    if alive.nil?
      age = this._stale_seconds()
      return "failed:zombie (no heartbeat for " + str(age / 60) + "m)" if age.present? && age > 600
    end
    s
  end

  static def _pid_alive(pid)
    return nil if pid.nil?
    res = System.run_sync([
      "kill",
      "-0",
      str(pid)
    ]) rescue {"exit_code": 1}
    res["exit_code"] == 0
  end

  def _stale_seconds()
    return nil if this.updated_at.nil? || this.updated_at == ""
    prior = DateTime.parse(this.updated_at).to_unix() rescue nil
    return nil if prior.nil?
    DateTime.now().to_unix() - prior
  end

  def _notify_if_status_changed()
    return nil if this._key.nil? || this._key == ""
    new_status = this.status ?? ""
    return nil if this.last_notified_status == new_status
    prev = CodeReview.find_by("_key", this._key) rescue nil
    return nil if prev.nil?
    prev_status = prev.status ?? ""
    return nil if prev_status == new_status
    this.last_notified_status = new_status
    title = "Code Review: " + (this.slug ?? "")
    url = "/projects/" + (this.project ?? "") + "/tasks/" + (this.slug ?? "")
    web_push_send_to_all({
      "title": title,
      "status": new_status,
      "url": url
    }) rescue null
  end

  def verdict()
    b = this.body ?? ""
    return nil if b == ""
    marker = "**Verdict:**"
    parts = b.split(marker)
    if parts.length() < 2
      plain_parts = b.split("Verdict:")
      return nil if plain_parts.length() < 2
      raw = plain_parts[1].split("\n")[0].trim()
      words = raw.split(" ")
      return words[0].replace("**", "") if words.length() > 0 && words[0].length() > 0
      return nil
    end
    line = parts[1].split("\n")[0].trim()
    words = line.split(" ")
    return words[0].replace("**", "") if words.length() > 0 && words[0].length() > 0
    nil
  end

  def touch_timestamps()
    now = DateTime.now().to_iso()
    this.created_at = now if this.created_at.nil?
    this.updated_at = now
    this._notify_if_status_changed()
  end
end

# WS payload builder for the code-review stream. Returns the same
# delta/snapshot shape as plan_stream_payload so the same client
# controller in public/run-stream.js can drive both.
fn code_review_stream_payload(review_id, event_type, offset)
  row = CodeReview.find_by_review_id(review_id)
  if row.nil?
    return {
      "event": "error",
      "terminal": true,
      "message": "unknown review"
    }
  end

  cursor = offset
  cursor = 0 if cursor.nil? || cursor < 0
  log = row.log ?? ""
  size = log.length
  cursor = 0 if cursor > size
  chunk = ""
  chunk = log.substring(cursor, size) if cursor < size
  status_token = row.effective_status
  done = status_token == "done"
  failed = status_token.starts_with("failed:")
  {
    "event": event_type == "connect" ? "snapshot" : "delta",
    "log_chunk": chunk,
    "log_offset": size,
    "status": status_token,
    "terminal": done || failed,
    "reload": done || failed
  }
end
