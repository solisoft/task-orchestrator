class DebugController < ApplicationController
  def comments_probe(req)
    lines = []
    lines.push("=== COMMENTS ===")
    comments = []
    try
      comments = Comment.all()
    catch e
      comments = []
    end
    for c in (comments ?? [])
      bids = c.attachment_blob_ids ?? []
      lines.push("  key=" + (c._key ?? "?") +
        "  feature=" + (c.feature_slug ?? "?") +
        "  blob_ids=" + str(bids))
    end
    {
      "status": 200,
      "headers": {"Content-Type": "text/plain"},
      "body": lines.join("\n")
    }
  end

  def unstamp_imported(req)
    key = (req["query"] ?? {})["feature"] ?? ""
    if key == ""
      return {"status": 422, "body": "feature query param is required"}
    end
    plans = Plan.all() rescue []
    n = 0
    for p in plans
      fs = p.feature_slug ?? ""
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

  def try_import(req)
    key = (req["query"] ?? {})["feature"] ?? ""
    if key == ""
      return {"status": 422, "body": "feature query param is required"}
    end
    feature = Feature.find_by("_key", key)
    if feature == nil
      return {"status": 404, "body": "feature not found: " + key}
    end
    plans = Plan.all() rescue []
    log = []
    for p in plans
      fs = p.feature_slug ?? ""
      if fs != key
        next
      end
      log.push("plan=" + p.plan_id + " status=" + (p.status ?? "") +
        " ti=" + str(p.tasks_imported) +
        " body_len=" + str((p.body ?? "").length()))
      body = p.body ?? ""
      raw = body.trim()
      log.push("  raw_len=" + str(raw.length()) +
        " contains_task_heading=" + str(raw.contains("## Task")))
      # Force a re-import attempt and surface the count.
      p.tasks_imported = false
      p.save()
      # Mirror _parse_task_sections + _create_tasks_from_body inline so
      # we can surface validation errors that bubble back from Task.create.
      sections = _parse_task_sections(body) rescue []
      log.push("  sections=" + str(sections.length()))
      i = 0
      for s in sections
        log.push("  section[" + str(i) + "] title=" + (s["title"] ?? "?") +
          " body_len=" + str((s["body"] ?? "").length()))
        title = s["title"] ?? ""
        raw_slug = title.slugify()
        log.push("    slug_raw=" + raw_slug)
        task = Task.create({
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

  def stamp_imported(req)
    key = (req["query"] ?? {})["feature"] ?? ""
    if key == ""
      return {"status": 422, "body": "feature query param is required"}
    end
    plans = Plan.all() rescue []
    n = 0
    for p in plans
      fs = p.feature_slug ?? ""
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

  def demote_feature_todos(req)
    key = (req["query"] ?? {})["feature"] ?? ""
    if key == ""
      return {"status": 422, "body": "feature query param is required"}
    end
    rows = Task.where({ "feature_slug": key, "status": "todo" }).all() rescue []
    n = 0
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

  def features_probe(req)
    lines = []
    lines.push("=== FEATURES ===")
    features = Feature.all() rescue []
    for f in features
      lines.push("  key=" + (f._key ?? "?") +
        "  status=" + (f.status ?? "?") +
        "  title=" + (f.title ?? "?"))
    end
    lines.push("")
    lines.push("=== PLANS (most recent first) ===")
    plans = Plan.all() rescue []
    plans = plans.sort_by(fn(p) p.plan_id ?? "").reverse()
    take = plans.length()
    if take > 8
      take = 8
    end
    i = 0
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
    tasks = Task.all() rescue []
    for t in tasks
      fs = t.feature_slug ?? ""
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

  def show(req)
    {
      "status": 200,
      "headers": {"Content-Type": "text/plain"},
      "body":
        "Task.count() = " + str(Task.count() rescue "ERR") + "\n" +
        "lang count = " +
          str((Task.where({ "project": "lang" }).all().length) rescue "ERR") + "\n" +
        "run_state_root = " + str(Run.run_state_root() rescue "ERR") + "\n"
    }
  end
end
