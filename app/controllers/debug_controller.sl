fn comments_probe(req)
  let lines = []
  lines.push("=== COMMENTS ===")
  for c in (Comment.all() rescue [])
    let bids = c.attachment_blob_ids ?? []
    lines.push("  key=" + (c._key ?? "?") +
               "  feature=" + (c.feature_slug ?? "?") +
               "  blob_ids=" + str(bids))
  end
  lines.push("")
  lines.push("=== comment_attachments collection ===")
  let rows = @sdbql{ FOR d IN comment_attachments RETURN d } rescue []
  for r in rows
    lines.push("  _key=" + str(r["_key"]) +
               "  name=" + str(r["name"]) +
               "  type=" + str(r["type"]) +
               "  size=" + str(r["size"]))
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/plain"},
    "body": lines.join("\n")
  }
end

fn unstamp_imported(req)
  let key = (req["query"] ?? {})["feature"] ?? ""
  if key == ""
    return {"status": 422, "body": "feature query param is required"}
  end
  let plans = Plan.all() rescue []
  let n = 0
  for p in plans
    let fs = p.feature_slug ?? ""
    if fs == key
      p.tasks_imported = false
      p.save()
      n = n + 1
    end
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/plain"},
    "body": "unstamped " + str(n) + " plan(s) for feature " + key + "\n"
  }
end

fn try_import(req)
  let key = (req["query"] ?? {})["feature"] ?? ""
  if key == ""
    return {"status": 422, "body": "feature query param is required"}
  end
  let feature = Feature.find_by("_key", key)
  if feature == nil
    return {"status": 404, "body": "feature not found: " + key}
  end
  let plans = Plan.all() rescue []
  let log = []
  for p in plans
    let fs = p.feature_slug ?? ""
    if fs != key
      next
    end
    log.push("plan=" + p.plan_id + " status=" + (p.status ?? "") +
             " ti=" + str(p.tasks_imported) +
             " body_len=" + str((p.body ?? "").length()))
    let body = p.body ?? ""
    let raw = body.trim()
    log.push("  raw_len=" + str(raw.length()) +
             " contains_task_heading=" + str(raw.contains("## Task")))
    # Force a re-import attempt and surface the count.
    p.tasks_imported = false
    p.save()
    # Mirror _parse_task_sections + _create_tasks_from_body inline so
    # we can surface validation errors that bubble back from Task.create.
    let sections = _parse_task_sections(body) rescue []
    log.push("  sections=" + str(sections.length()))
    let i = 0
    for s in sections
      log.push("  section[" + str(i) + "] title=" + (s["title"] ?? "?") +
               " body_len=" + str((s["body"] ?? "").length()))
      let title = s["title"] ?? ""
      let raw_slug = title.slugify()
      log.push("    slug_raw=" + raw_slug)
      let task = Task.create({
        "_key":         Task.key_for(feature.project, raw_slug),
        "project":      feature.project,
        "slug":         raw_slug,
        "title":        title,
        "body_md":      s["body"] ?? "",
        "status":       "proposed",
        "feature_slug": feature._key,
        "author":       ""
      })
      if task._errors
        log.push("    errors=" + str(task._errors))
      else
        log.push("    created ok")
      end
      i = i + 1
    end
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/plain"},
    "body": log.join("\n")
  }
end

fn stamp_imported(req)
  let key = (req["query"] ?? {})["feature"] ?? ""
  if key == ""
    return {"status": 422, "body": "feature query param is required"}
  end
  let plans = Plan.all() rescue []
  let n = 0
  for p in plans
    let fs = p.feature_slug ?? ""
    if fs == key and p.tasks_imported != true
      p.tasks_imported = true
      p.save()
      n = n + 1
    end
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/plain"},
    "body": "stamped " + str(n) + " plan(s) for feature " + key + " as imported\n"
  }
end

fn demote_feature_todos(req)
  let key = (req["query"] ?? {})["feature"] ?? ""
  if key == ""
    return {"status": 422, "body": "feature query param is required"}
  end
  let rows = Task.where({ "feature_slug": key, "status": "todo" }).all() rescue []
  let n = 0
  for t in rows
    t.status = "proposed"
    t.save()
    n = n + 1
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/plain"},
    "body": "demoted " + str(n) + " task(s) for feature " + key + " back to proposed\n"
  }
end

fn features_probe(req)
  let lines = []
  lines.push("=== FEATURES ===")
  let features = Feature.all() rescue []
  for f in features
    lines.push("  key=" + (f._key ?? "?") +
               "  status=" + (f.status ?? "?") +
               "  title=" + (f.title ?? "?"))
  end
  lines.push("")
  lines.push("=== PLANS (most recent first) ===")
  let plans = Plan.all() rescue []
  plans = plans.sort_by(fn(p) p.plan_id ?? "").reverse()
  let take = plans.length()
  if take > 8
    take = 8
  end
  let i = 0
  for p in plans
    if i >= take
      next
    end
    lines.push("  " + (p.plan_id ?? "?") +
               "  status=" + (p.status ?? "?") +
               "  proj=" + (p.project ?? "?") +
               "  fslug=" + str(p.feature_slug ?? "nil") +
               "  ti=" + str(p.tasks_imported))
    i = i + 1
  end
  lines.push("")
  lines.push("=== TASKS linked to features ===")
  let tasks = Task.all() rescue []
  for t in tasks
    let fs = t.feature_slug ?? ""
    if fs != ""
      lines.push("  proj=" + (t.project ?? "?") +
                 "  slug=" + (t.slug ?? "?") +
                 "  status=" + (t.status ?? "?") +
                 "  fslug=" + fs)
    end
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/plain; charset=utf-8"},
    "body": lines.join("\n")
  }
end

fn show(req)
  {
    "status": 200,
    "headers": {"Content-Type": "text/plain"},
    "body":
      "Task.count() = " + str(Task.count() rescue "ERR") + "\n" +
      "lang count = " +
        str((Task.where({ "project": "lang" }).all().length) rescue "ERR") + "\n" +
      "run_state_root = " + str(run_state_root() rescue "ERR") + "\n"
  }
end

