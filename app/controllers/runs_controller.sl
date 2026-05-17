# Live agent-run viewer. The HTML page (GET) is the chrome; the
# `/log` endpoint (GET, HTMX-target) returns just the tail fragment so
# polling is cheap and the surrounding page doesn't redraw.

class RunsController < ApplicationController
  title:       Any
  project:     Any
  task:        Any
  slug:        Any
  status:      Any
  pr_url:      Any
  tail:        Any
  log_size:    Any
  todos:       Any
  branch_info: Any

  def show(req)
    project = Project.find_project(req["params"]["name"])
    if project == nil
      return {"status": 404, "body": "Unknown project"}
    end
    slug = req["params"]["slug"]
    task = Task.find_by_slug(project["name"], slug)
    if task == nil
      return {"status": 404, "body": "Task not found"}
    end
    @title          = "Run · " + slug
    @project        = project
    @task           = task
    @slug           = slug
    @status         = Run.run_current_status(project["name"], slug)
    @pr_url         = Run.run_pr_url(project["name"], slug)
    @tail           = Run.run_log_tail(project["name"], slug, 16384)
    @log_size       = Run.run_log_size(project["name"], slug)
    @todos          = Run.run_latest_todos(project["name"], slug)
    @branch_info    = _branch_info_for(task, project)
    render("runs/show")
  end

  # POST /projects/:name/tasks/:slug/run/resume — re-launch a dead run
  # in its existing worktree. Valid when the row is `failed`, or when
  # it's still `inprogress` but the wrapper process is gone (zombie:
  # `run_indicator` returns "failed" via the synthesized status). Spawns
  # `bin/task-run --resume` detached and bounces back to the run page so
  # the polling viewer picks up the new transcript.
  def resume(req)
    project = Project.find_project(req["params"]["name"])
    if project == nil
      return {"status": 404, "body": "Unknown project"}
    end
    slug = req["params"]["slug"]
    task = Task.find_by_slug(project["name"], slug)
    if task == nil
      return {"status": 404, "body": "Task not found"}
    end

    # Resumable iff the row is failed, OR we're "inprogress" but the
    # liveness check has flagged the run as a zombie. Anything else
    # (queued, done, todo) is a no-op refused at the boundary.
    indicator = Run.run_indicator(project["name"], slug)
    resumable = task.status == "failed" or
                    (task.status == "inprogress" and indicator == "failed")
    if not resumable
      return {"status": 422,
              "body": "task is not in a resumable state (status=" + task.status +
                      ", indicator=" + (indicator ?? "nil") + ")"}
    end

    # The worktree is the whole point of `--resume` — without it,
    # `bin/task-run` would `fail` and the user would just see another
    # dead run. Refuse here with a clearer error.
    if not Run.run_worktree_exists(project["name"], slug)
      return {"status": 422,
              "body": "no worktree at " + Run.run_worktree_path(project["name"], slug) +
                      " — re-queue the task instead of resuming"}
    end

    task.resume!()

    line = "nohup ./bin/task-run --resume " +
      project["name"] + " " + slug +
      " >/dev/null 2>&1 & disown"
    System.run_sync(["bash", "-c", line]) rescue null

    redirect("/projects/" + project["name"] + "/tasks/" + slug + "/run")
  end

  def log(req)
    project = Project.find_project(req["params"]["name"])
    if project == nil
      return {"status": 404, "body": "Unknown project"}
    end
    slug = req["params"]["slug"]
    task = Task.find_by_slug(project["name"], slug)
    if task == nil
      return {"status": 404, "body": "Task not found"}
    end
    {
      "status": 200,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": render_partial("runs/log", {
        "project": project,
        "task": task,
        "slug": slug,
        "status": Run.run_current_status(project["name"], slug),
        "pr_url": Run.run_pr_url(project["name"], slug),
        "tail": Run.run_log_tail(project["name"], slug, 16384),
        "log_size": Run.run_log_size(project["name"], slug),
        "todos": Run.run_latest_todos(project["name"], slug)
      })
    }
  end

  # WebSocket handler for the live run viewer.
  #
  # Protocol — server -> client (all JSON):
  #   { "event": "snapshot", "log_chunk": "...", "log_offset": N,
  #     "prefix_chunk": "...",          # only when client sent prefix_end>0;
  #                                     # bytes 0..prefix_end that SSR omitted
  #     "status_html": "...", "todos_html": "...",
  #     "terminal": false }
  #   { "event": "delta",    "log_chunk": "...", "log_offset": N,
  #     "status_html": "...", "todos_html": "...",
  #     "terminal": false }
  #   On terminal status, the same delta shape with `"terminal": true`.
  #
  # Protocol — client -> server:
  #   { "type": "subscribe", "offset": N, "prefix_end": M }
  #   { "type": "tick",      "offset": N }
  # `prefix_end` is sent once at subscribe to backfill the prefix the SSR
  # `run_log_tail` cap left off the initial paint.
  #
  # Why polling-over-WS instead of true push: Soli's WS handler is event
  # driven (no long-running loop) and there's no in-process publisher
  # tied to `bin/task-run`'s file writes. The client tick keeps round
  # trips client-driven; the WS layer is the win — one persistent
  # connection, delta-only payload, sub-second latency.
  #
  # NOTE: the actual handler is the top-level `stream(event)` fn below.
  # Soli's WebSocket dispatcher (Soli 1.1.1) resolves `tasks#stream`-style
  # action strings through the global env, not the OOP controller registry,
  # so WS handlers must remain top-level free fns even when the rest of the
  # controller is class-based.
end

fn stream(event)
  event_type = event["type"]
  if event_type != "message"
    # Connect / disconnect carry no identifiers — Soli's `router_websocket`
    # routes are static, so the client tells us which run to stream by
    # echoing `project` + `slug` on every tick. We just acknowledge the
    # other lifecycle events with an empty hash.
    return {}
  end
  raw = (event["message"] ?? "").trim()
  parsed = JSON.parse(raw) rescue nil
  if parsed == nil
    return { "send": JSON.stringify({ "event": "error", "message": "bad message", "terminal": true }) }
  end
  name = (parsed["project"] ?? "").trim()
  slug = (parsed["slug"] ?? "").trim()
  project = Project.find_project(name) rescue nil
  if project == nil
    return { "send": JSON.stringify({ "event": "error", "message": "unknown project", "terminal": true }) }
  end
  task = Task.find_by_slug(project["name"], slug) rescue nil
  if task == nil
    return { "send": JSON.stringify({ "event": "error", "message": "task not found", "terminal": true }) }
  end
  offset = parsed["offset"] ?? 0
  prefix_end = parsed["prefix_end"] ?? 0
  frame_kind = parsed["type"] == "subscribe" ? "connect" : "message"
  data = Run.run_stream_payload(project["name"], slug, frame_kind, offset, prefix_end)
  data["status_html"] = render_partial("runs/stream_status", {
    "project": project,
    "slug":    slug,
    "task":    task,
    "status":  data["status"],
    "pr_url":  data["pr_url"]
  })
  data["todos_html"] = render_partial("runs/stream_todos", { "todos": data["todos"] })
  { "send": JSON.stringify(data) }
end
