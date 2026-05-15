# Home — `/` branches on auth state:
#   anonymous     → marketing landing (home/landing.html.slv)
#   authenticated → workspace inbox (home/workspace.html.slv)

fn landing(req)
  let _email = session_get("user_email") ?? ""
  let _user = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
  if _user != nil
    return _render_workspace(req, _user)
  end
  let project_count = list_projects() rescue []
  let feature_total = (Feature.count() rescue 0)
  render("home/landing", {
    "title":          "Task Orchestrator — product briefs that ship",
    "project_count":  project_count.length(),
    "feature_total":  feature_total,
    "current_user":   _user,
    "hide_header":    true,
    "theme":          Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class":    Setting.current_theme_class()
  })
end

# Workspace inbox — sections that surface "what needs your attention"
# across every project. One Task.all() pass (via `_workspace_buckets`)
# powers all four sections.
fn _render_workspace(req, user)
  let buckets = _workspace_buckets()
  render("home/workspace", {
    "title":          "Workspace",
    "review":         buckets["review"],
    "failed_recent":  buckets["failed_recent"],
    "long_running":   buckets["long_running"],
    "shipped_recent": buckets["shipped_recent"],
    "current_user":   user,
    "theme":          Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class":    Setting.current_theme_class()
  })
end

# Single pass over Task.all() bucketing into the four workspace sections.
# 30-minute long-run threshold mirrors the dispatcher's own boundary.
fn _workspace_buckets()
  let now = (DateTime.now().to_unix() rescue 0)
  let day_cutoff = now - 86400
  let long_run_cutoff = now - 1800
  let review = []
  let failed_recent = []
  let long_running = []
  let shipped_recent = []
  for t in (Task.all() rescue [])
    let s = t.status ?? ""
    if s == "review"
      review.push(t)
      next
    end
    let unix = _safe_unix(t.finished_at) ?? _safe_unix(t.updated_at)
    if s == "failed" and unix != nil and unix >= day_cutoff
      failed_recent.push(t)
      next
    end
    if s == "done" and unix != nil and unix >= day_cutoff
      shipped_recent.push(t)
      next
    end
    if s == "inprogress"
      let started = _safe_unix(t.started_at)
      if started != nil and started < long_run_cutoff
        long_running.push(t)
      end
    end
  end
  {
    "review":         _sort_by_updated_desc(review),
    "failed_recent":  _sort_by_updated_desc(failed_recent),
    "long_running":   _sort_by_updated_desc(long_running),
    "shipped_recent": _sort_by_updated_desc(shipped_recent)
  }
end

fn _safe_unix(iso)
  if iso == nil or iso == ""
    return nil
  end
  let dt = DateTime.parse(iso) rescue nil
  if dt == nil
    return nil
  end
  dt.to_unix() rescue nil
end

fn _sort_by_updated_desc(tasks)
  tasks.sort_by(fn(t) (t.updated_at ?? "") end).reverse()
end

fn health(req)
  {
    "status": 200,
    "headers": {"Content-Type": "application/json"},
    "body": "{\"status\":\"ok\"}"
  }
end
