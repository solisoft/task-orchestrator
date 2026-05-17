# Home — `/` branches on auth state:
#   anonymous     → marketing landing (home/landing.html.slv)
#   authenticated → workspace inbox (home/workspace.html.slv)

class HomeController < ApplicationController
  title:          Any
  current_user:   Any
  hide_header:    Any
  project_count:  Any
  feature_total:  Any
  review:         Any
  failed_recent:  Any
  long_running:   Any
  shipped_recent: Any

  def landing(req)
    _email = session_get("user_email") ?? ""
    _user = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
    if _user != nil
      return this._render_workspace(req, _user)
    end
    project_count = Project.list_projects() rescue []
    @title          = "Task Orchestrator — product briefs that ship"
    @project_count  = project_count.length()
    @feature_total  = (Feature.count() rescue 0)
    @current_user   = _user
    @hide_header    = true
    render("home/landing")
  end

  # Workspace inbox — sections that surface "what needs your attention"
  # across every project. One Task.all() pass (via `_workspace_buckets`)
  # powers all four sections.
  def _render_workspace(req, user)
    buckets = this._workspace_buckets()
    @title          = "Workspace"
    @review         = buckets["review"]
    @failed_recent  = buckets["failed_recent"]
    @long_running   = buckets["long_running"]
    @shipped_recent = buckets["shipped_recent"]
    @current_user   = user
    render("home/workspace")
  end

  # Single pass over Task.all() bucketing into the four workspace sections.
  # 30-minute long-run threshold mirrors the dispatcher's own boundary.
  def _workspace_buckets()
    now = (DateTime.now().to_unix() rescue 0)
    day_cutoff = now - 86400
    long_run_cutoff = now - 1800
    review = []
    failed_recent = []
    long_running = []
    shipped_recent = []
    for t in (Task.all() rescue [])
      s = t.status ?? ""
      if s == "review"
        review.push(t)
        next
      end
      unix = this._safe_unix(t.finished_at) ?? this._safe_unix(t.updated_at)
      if s == "failed" and unix != nil and unix >= day_cutoff
        failed_recent.push(t)
        next
      end
      if s == "done" and unix != nil and unix >= day_cutoff
        shipped_recent.push(t)
        next
      end
      if s == "inprogress"
        started = this._safe_unix(t.started_at)
        if started != nil and started < long_run_cutoff
          long_running.push(t)
        end
      end
    end
    {
      "review":         this._sort_by_updated_desc(review),
      "failed_recent":  this._sort_by_updated_desc(failed_recent),
      "long_running":   this._sort_by_updated_desc(long_running),
      "shipped_recent": this._sort_by_updated_desc(shipped_recent)
    }
  end

  def _safe_unix(iso)
    if iso == nil or iso == ""
      return nil
    end
    dt = DateTime.parse(iso) rescue nil
    if dt == nil
      return nil
    end
    dt.to_unix() rescue nil
  end

  def _sort_by_updated_desc(tasks)
    tasks.sort_by(fn(t) (t.updated_at ?? "") end).reverse()
  end

  def health(req)
    {
      "status": 200,
      "headers": {"Content-Type": "application/json"},
      "body": "{\"status\":\"ok\"}"
    }
  end
end
