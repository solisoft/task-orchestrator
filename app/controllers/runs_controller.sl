import { find_project, run_current_status, run_pr_url } from "../helpers/model_exports.sl"
import { run_log_tail, run_latest_todos, run_indicator } from "../helpers/model_exports.sl"
import { run_worktree_exists, run_worktree_path } from "../helpers/model_exports.sl"

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
    "tail": run_log_tail(project["name"], slug, 16384),
    "todos": run_latest_todos(project["name"], slug),
    "branch_info": _branch_info_for(task, project),
    "theme": Setting.current_theme()
  })
end

# POST /projects/:name/tasks/:slug/run/resume — re-launch a dead run
# in its existing worktree. Valid when the row is `failed`, or when
# it's still `inprogress` but the wrapper process is gone (zombie:
# `run_indicator` returns "failed" via the synthesized status). Spawns
# `bin/task-run --resume` detached and bounces back to the run page so
# the polling viewer picks up the new transcript.
fn resume(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let slug = req["params"]["slug"]
  let task = Task.find_by_slug(project["name"], slug)
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end

  # Resumable iff the row is failed, OR we're "inprogress" but the
  # liveness check has flagged the run as a zombie. Anything else
  # (queued, done, todo) is a no-op refused at the boundary.
  let indicator = run_indicator(project["name"], slug)
  let resumable = task.status == "failed" or
                  (task.status == "inprogress" and indicator == "failed")
  if not resumable
    return {"status": 422,
            "body": "task is not in a resumable state (status=" + task.status +
                    ", indicator=" + (indicator ?? "nil") + ")"}
  end

  # The worktree is the whole point of `--resume` — without it,
  # `bin/task-run` would `fail` and the user would just see another
  # dead run. Refuse here with a clearer error.
  if not run_worktree_exists(project["name"], slug)
    return {"status": 422,
            "body": "no worktree at " + run_worktree_path(project["name"], slug) +
                    " — re-queue the task instead of resuming"}
  end

  task.resume!()

  let line = "nohup ./bin/task-run --resume " +
             project["name"] + " " + slug +
             " >/dev/null 2>&1 & disown"
  System.run_sync(["bash", "-c", line]) rescue null

  redirect("/projects/" + project["name"] + "/tasks/" + slug + "/run")
end

fn log(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let slug = req["params"]["slug"]
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": render_partial("runs/log", {
      "project": project,
      "slug": slug,
      "status": run_current_status(project["name"], slug),
      "pr_url": run_pr_url(project["name"], slug),
      "tail": run_log_tail(project["name"], slug, 16384),
      "todos": run_latest_todos(project["name"], slug)
    })
  }
end
