# Task viewer + queue/save/new actions. All persistence goes through
# `Task < Model` (solidb-backed). The `.md` files in `tasks/<status>/`
# are no longer the source of truth — they're historical artefacts.

fn new(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project: " + req["params"]["name"]}
  end
  render("tasks/new", {
    "title": "New task — " + project["name"],
    "project": project,
    "task": null
  })
end

fn create(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let body = req["form"]["body_md"] ?? ""
  let title = (req["form"]["title"] ?? "").trim()
  # Title falls back to the body's first `# ...` heading; slug is derived
  # from the title (lowercased + dashed). Collisions append `-2`, `-3`, …
  # so the user never has to think about the URL piece.
  if title == ""
    title = parse_title_from_body(body)
  end
  if title == ""
    return {"status": 422, "body": "Need a title (or a `# heading` line in the body)"}
  end
  let slug = unique_slug_for(project["name"], title.slugify())
  let task = Task.create({
    "_key":    Task.key_for(project["name"], slug),
    "project": project["name"],
    "slug":    slug,
    "title":   title,
    "body_md": body,
    "status":  "todo"
  })
  if task._errors
    return render("tasks/new", {
      "title": "New task — " + project["name"],
      "project": project,
      "task": task
    })
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
end

# Pull the first `# ...` heading line out of a markdown body, with the
# leading hashes/whitespace stripped. Returns "" if the body has none.
fn parse_title_from_body(body)
  for line in body.split("\n")
    let s = line.trim()
    if s.starts_with("# ") and not s.starts_with("## ")
      return s.substring(2, s.length).trim()
    end
  end
  ""
end

# Append `-N` to `base` until no row in solidb's `tasks` collection
# has the same (project, slug) pair. Caps at 100 attempts to avoid
# pathological loops.
fn unique_slug_for(project_name, base)
  if base == ""
    base = "task"
  end
  let candidate = base
  let n = 2
  while Task.find_by_slug(project_name, candidate) != nil and n <= 100
    candidate = base + "-" + str(n)
    n = n + 1
  end
  candidate
end

fn show(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found: " + req["params"]["slug"]}
  end
  render("tasks/show", {
    "title": task.slug,
    "project": project,
    "task": task
  })
end

fn save(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  if task.status != "todo"
    return {"status": 422, "body": "Can only edit tasks in todo (current: " + task.status + ")"}
  end
  task.body_md = req["form"]["body_md"] ?? ""
  let title = (req["form"]["title"] ?? "").trim()
  if title != ""
    task.title = title
  end
  task.save()
  if task._errors
    return render("tasks/show", {
      "title": task.slug,
      "project": project,
      "task": task
    })
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
end

fn queue(req)
  move_response(req, fn(t) t.queue!())
end

fn unqueue(req)
  move_response(req, fn(t) {
    t.unqueue!()
    clear_run_state(t.project, t.slug)
  })
end

# Shared dispatch for queue/unqueue. HTMX requests get the live board
# fragment (so the kanban swaps in place); plain form posts get the full
# redirect to the project page.
# Take rough notes and have the `/plan-task` skill expand them into a
# structured task spec. HTMX-target the body textarea on the new-task
# form so the result swaps in place.
fn plan(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let notes = (req["form"]["body_md"] ?? "").trim()
  if notes == ""
    return {"status": 422, "body": "Notes required — type a few lines first"}
  end
  let result = run_plan_agent(notes)
  if result["error"] != nil
    return {
      "status": 502,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": "<div class=\"text-red-300 text-sm p-3\">plan failed: " + h(result["error"]) + "</div>"
    }
  end
  let title = parse_title_from_body(result["body"])
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": render_partial("tasks/planned_body", {
      "body":  result["body"],
      "title": title
    })
  }
end

# Spawn `claude -p "/plan-task <tmpfile>"`. The skill is at
# .claude/skills/plan-task/SKILL.md in this repo, so claude finds it
# because the dev server's cwd is the project root. Returns either
# `{ "body": <markdown> }` or `{ "error": <reason> }`.
fn run_plan_agent(notes)
  let nonce = str(DateTime.now().to_unix() rescue 0)
  let path = "/tmp/plan-task-" + nonce + ".md"
  Trusted.write(path, notes)
  let res = System.run_sync([
    "claude", "--dangerously-skip-permissions", "-p", "/plan-task " + path
  ])
  System.run_sync(["rm", "-f", path])
  if res["exit_code"] != 0
    return { "error": "claude exit=" + str(res["exit_code"]) + " stderr=" + res["stderr"] }
  end
  let body = strip_code_fences(res["stdout"].trim())
  if body == ""
    return { "error": "claude returned empty output" }
  end
  { "body": body }
end

# Defensive: if the model wraps the spec in ```md ... ``` fences (older
# instructions did this), peel them off so they don't end up in the
# textarea.
fn strip_code_fences(s)
  let t = s.trim()
  if not t.starts_with("```")
    return t
  end
  let nl = t.index_of("\n")
  if nl < 0
    return t
  end
  let inner = t.substring(nl + 1, t.length).trim()
  if inner.ends_with("```")
    inner = inner.substring(0, inner.length - 3).trim()
  end
  inner
end

fn move_response(req, action)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  action(task)
  if task._errors
    return {"status": 422, "body": "Save failed"}
  end
  if req["headers"]["hx-request"] == "true"
    let columns = Task.board_for(project["name"])
    # After an action the task's new status is the most useful tab to
    # land on — the user sees the row appear in its new column.
    let active = task.status
    if columns[active] == nil
      active = "todo"
    end
    return {
      "status": 200,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": render_partial("projects/board", {
        "project": project,
        "columns": columns,
        "indicators": indicators_for(project["name"], columns),
        "statuses": Task.kanban_statuses(),
        "active_tab": active
      })
    }
  end
  redirect("/projects/" + project["name"])
end
