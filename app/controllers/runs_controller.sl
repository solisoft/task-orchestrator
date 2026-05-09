# Live agent-run viewer. The HTML page (GET) is the chrome; the
# `/log` endpoint (GET, HTMX-target) returns just the tail fragment so
# polling is cheap and the surrounding page doesn't redraw.

fn show(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let slug = req["params"]["slug"]
  let task = Task.find_by_slug(project["name"], slug)
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  render("runs/show", {
    "title": "Run · " + slug,
    "project": project,
    "task": task,
    "slug": slug,
    "status": run_current_status(project["name"], slug),
    "pr_url": run_pr_url(project["name"], slug),
    "tail": run_log_tail(project["name"], slug, 16384)
  })
end
fn log(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let slug = req["params"]["slug"]
  # Refetch the task on every poll so `pending_question` reflects the
  # latest agent state — that's what drives the in-flight question form.
  let task = Task.find_by_slug(project["name"], slug)
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": render_partial("runs/log_poll", {
      "project": project,
      "slug": slug,
      "task": task,
      "status": run_current_status(project["name"], slug),
      "pr_url": run_pr_url(project["name"], slug),
      "tail": run_log_tail(project["name"], slug, 16384)
    })
  }
end
