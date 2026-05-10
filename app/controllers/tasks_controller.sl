# Task viewer + queue/save/new actions. All persistence goes through
# `Task < Model` (solidb-backed). The `.md` files in `tasks/<status>/`
# are no longer the source of truth — they're historical artefacts.

fn new(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project: " + req["params"]["name"]}
  end
  # If the URL carries ?plan_id=…, hydrate the right stage of the form
  # server-side so a reload during planning doesn't drop the user back
  # to Stage 1 with an empty notes textarea — the runner is still alive
  # in the background; we just lost the DOM state.
  let plan_id = ((req["params"]["plan_id"]
                 ?? (req["query"] == nil ? nil : req["query"]["plan_id"]))
                 ?? "").trim()
  let plan_state = nil
  let plan_title = ""
  if plan_id != ""
    # Probe the status journal so a bogus plan_id doesn't loop the
    # polling forever against a runner that never existed.
    let probe = Trusted.read(run_state_root() + "/_plans/" + plan_id + "/status") rescue nil
    if probe != nil
      plan_state = read_plan_state(plan_id)
      if plan_state["status"] == "done"
        plan_title = parse_title_from_body(plan_state["body"])
      end
    end
  end
  render("tasks/new", {
    "title":           "New task — " + project["name"],
    "project":         project,
    "task":            null,
    "plan_id":         plan_id == "" ? nil : plan_id,
    "plan_state":      plan_state,
    "plan_title":      plan_title,
    "opencode_models": list_opencode_models()
  })
end

# Shell out to `opencode models`, return the (possibly empty) list of
# `provider/model` strings. We do this on every page load so the
# dropdown reflects whatever opencode currently has configured —
# providers come and go faster than we want to redeploy.
# Failures (binary missing, no credentials) silently degrade to an
# empty list, which the view renders as "no opencode optgroup".
fn list_opencode_models()
  let res = System.run_sync(["opencode", "models"]) rescue nil
  if res == nil or res["exit_code"] != 0
    return []
  end
  let lines = (res["stdout"] ?? "").split("\n")
  let out = []
  for line in lines
    let s = line.trim()
    # Shape-validate every line before we let it touch the form: the
    # value reaches a shell command line via `spawn_plan_agent`, so
    # nothing past this regex should ever ship to bash.
    if _looks_like_opencode_model(s)
      out.push(s)
    end
  end
  out
end

# Shape gate for an opencode model id ("provider/model" with an
# optional ":variant" reasoning-effort suffix, e.g.
# "deepseek/deepseek-v4-pro:low"). We deliberately avoid string-
# equality against `opencode models` output at validate time: that
# list shifts under us, and shell injection is the only thing we
# actually need to defend against. Restricting each segment to a
# narrow charset is enough.
fn _looks_like_opencode_model(s)
  if s.length() == 0 or s.length() > 200
    return false
  end
  let slash = s.index_of("/")
  if slash <= 0 or slash == s.length() - 1
    return false
  end
  let provider = s.substring(0, slash)
  let rest     = s.substring(slash + 1, s.length)
  let colon    = rest.index_of(":")
  let model    = rest
  let variant  = ""
  if colon > 0
    model   = rest.substring(0, colon)
    variant = rest.substring(colon + 1, rest.length)
  end
  if not _matches_charset(provider, "provider") or not _matches_charset(model, "model")
    return false
  end
  if variant.length() > 0 and not _matches_charset(variant, "variant")
    return false
  end
  return true
end

fn _matches_charset(s, kind)
  if s.length() == 0
    return false
  end
  let i = 0
  while i < s.length()
    let c = s.substring(i, i + 1)
    let ok = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
            or (c >= "0" and c <= "9") or c == "-" or c == "_"
    # Model segment also allows "." (e.g. "MiniMax-M2.5").
    if not ok and kind == "model" and c == "."
      ok = true
    end
    # Variants are lowercase ascii only ("low", "medium", "high",
    # "minimal", "max"). Stricter than the model/provider charset on
    # purpose — keeps the surface small.
    if kind == "variant"
      ok = c >= "a" and c <= "z"
    end
    if not ok
      return false
    end
    i = i + 1
  end
  return true
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
  # Persist the model the user picked on the new-task form so /do-task
  # runs through the same agent they chose for planning. _allow_plan_model
  # already validates against the SDK allowlist + the opencode shape,
  # so the value is safe to store and forward to bin/task-run.
  let model = _stitched_plan_model(req["form"])
  let task = Task.create({
    "_key":    Task.key_for(project["name"], slug),
    "project": project["name"],
    "slug":    slug,
    "title":   title,
    "body_md": body,
    "model":   model,
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
    "task": task,
    "branch_info": _branch_info_for(task, project)
  })
end

# Hash describing the per-task git branch for the merge UI on the
# task page, or nil when the task isn't a candidate (only "done"
# rows with `outcome=local-branch` are — PR-mode tasks already show
# the PR link in the run log). Returns:
#   { "name": "task/<slug>", "main": "main"|"master",
#     "exists": Bool, "merged": Bool }
fn _branch_info_for(task, project)
  if task.status != "done" or task.outcome != "local-branch"
    return nil
  end
  {
    "name":   task_branch_name(task.slug),
    "main":   project_main_branch(project["path"]),
    "exists": task_branch_exists(project["path"], task.slug),
    "merged": task_branch_merged(project["path"], task.slug)
  }
end

# POST /projects/:name/tasks/:slug/merge — merge the per-task branch
# into the project's main branch. Only valid for `done` tasks whose
# outcome was `local-branch` (no PR was opened). The merge itself is
# guarded by `merge_task_branch` (refuses to switch branches or run
# on a dirty tree).
fn merge_branch(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  if task.status != "done" or task.outcome != "local-branch"
    return {"status": 422,
            "body": "merge is only available for done tasks with a local branch"}
  end
  if not task_branch_exists(project["path"], task.slug)
    return {"status": 422,
            "body": "branch " + task_branch_name(task.slug) + " not found in " +
                    project["path"]}
  end
  let result = merge_task_branch(project["path"], task.slug)
  if not result["ok"]
    return {"status": 422, "body": "merge failed: " + result["error"]}
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
end

fn mark_done(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  if task.status != "review"
    return {"status": 422,
            "body": "mark-done is only available for review tasks (current: " +
                    task.status + ")"}
  end
  if task.pr_url != nil and task.pr_url != ""
    if not pr_merged(task.pr_url)
      return {"status": 422, "body": "PR is not merged yet"}
    end
  end
  task.status = "done"
  task.finished_at = DateTime.now().to_iso()
  task.save()
  if task._errors
    return {"status": 422, "body": "Save failed"}
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
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
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  let denied = _queue_limit_denial(task)
  if denied != nil
    return _queue_limit_response(req, project, denied)
  end
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

# Take the user's rough notes, spawn bin/plan-run in the background, and
# return the Stage-2 progress partial. The runner drives the /plan-task
# skill through the Claude Agent SDK so canUseTool can intercept
# AskUserQuestion / ExitPlanMode and surface them as a question card —
# the user clicks an option to answer.
fn plan(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let notes = (req["form"]["body_md"] ?? "").trim()
  if notes == ""
    return {"status": 422, "body": "Notes required — type a few lines first"}
  end
  let model = _stitched_plan_model(req["form"])
  let plan_id = spawn_plan_agent(notes, model, project["path"])
  if plan_id == nil
    return {
      "status": 500,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": "<div class=\"text-red-300 text-sm p-3\">failed to spawn plan-run; check the server log</div>"
    }
  end
  # HX-Push-Url puts the plan_id in the address bar so a reload during
  # planning lands back on the same in-flight stage instead of an empty
  # Stage 1 form (see `new` action for the rehydration logic).
  {
    "status": 200,
    "headers": {
      "Content-Type": "text/html; charset=utf-8",
      "HX-Push-Url":  "/projects/" + project["name"] + "/tasks/new?plan_id=" + plan_id
    },
    "body": render_partial("tasks/plan_progress", {
      "project":          project,
      "plan_id":          plan_id,
      "log":              "",
      "status":           "starting",
      "pending_question": nil,
      "prompt":           notes
    })
  }
end

# HTMX poll endpoint for the in-flight plan agent. Tails the log file
# and, when the runner has flagged status=done, swaps the textarea to
# the planned body via render_partial("tasks/planned_body"). Polling
# stops automatically because that partial doesn't carry hx-* attrs.
fn plan_log(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let plan_id = req["params"]["plan_id"]
  let state = read_plan_state(plan_id)
  if state["status"] == "done"
    let title = parse_title_from_body(state["body"])
    return {
      "status": 200,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": render_partial("tasks/planned_body", {
        "project":         project,
        "plan_id":         plan_id,
        "body":            state["body"],
        "title":           title,
        "model":           state["model"],
        "opencode_models": list_opencode_models()
      })
    }
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": render_partial("tasks/plan_progress", {
      "project":          project,
      "plan_id":          plan_id,
      "log":              state["log"],
      "status":           state["status"],
      "pending_question": state["pending_question"],
      "prompt":           state["prompt"]
    })
  }
end

# Refine the current draft. Spawns a NEW plan_id (so the prior log /
# transcript is preserved) seeded with the previous spec plus the
# user's revision note, framed so /plan-task treats it as a revision
# rather than starting from scratch. Defaults the model to whatever
# was used the first time, but accepts an override from the form.
fn plan_refine(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let prev_plan_id = req["params"]["plan_id"]
  let prev_body = (req["form"]["body_md"] ?? "").trim()
  let note = (req["form"]["refine_note"] ?? "").trim()
  if note == ""
    return {"status": 422, "body": "Refinement note is empty — type what you want changed"}
  end
  if prev_body == ""
    return {"status": 422, "body": "Cannot refine an empty draft"}
  end
  # On refine, fall back to the previous plan's stored model when the
  # form didn't resubmit one (rare — the dropdown is always in the DOM).
  let prev_model = _read_plan_model(prev_plan_id)
  let form = req["form"]
  let submitted_model = form["plan_model"] ?? ""
  if submitted_model == ""
    form["plan_model"] = prev_model
  end
  let model = _stitched_plan_model(form)
  let seeded = "Previous draft of the task spec:\n\n"
              + prev_body
              + "\n\n---\n\n"
              + "Revise the spec per this note from the user:\n\n"
              + note
              + "\n\nProduce the FULL updated spec in the same shape "
              + "(no explanation, no diff — just the new spec)."
  let plan_id = spawn_plan_agent(seeded, model, project["path"])
  if plan_id == nil
    return {
      "status": 500,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": "<div class=\"text-red-300 text-sm p-3\">failed to spawn plan-run</div>"
    }
  end
  {
    "status": 200,
    "headers": {
      "Content-Type": "text/html; charset=utf-8",
      "HX-Push-Url":  "/projects/" + project["name"] + "/tasks/new?plan_id=" + plan_id
    },
    "body": render_partial("tasks/plan_progress", {
      "project":          project,
      "plan_id":          plan_id,
      "log":              "",
      "status":           "starting",
      "pending_question": nil,
      "prompt":           "Refining draft from " + prev_plan_id + ":\n\n" + note
    })
  }
end

# Read the model the user picked when this plan was first spawned.
# Falls back to the canonical default so a missing/corrupt file never
# raises into the refine flow.
fn _read_plan_model(plan_id)
  let v = (Trusted.read(run_state_root() + "/_plans/" + plan_id + "/model") rescue "").trim()
  if v == ""
    return "claude-sonnet-4-6"
  end
  v
end

# Write the user's reply to the SDK runner's polling location.
# File-based since planning has no DB row.
fn plan_answer(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let plan_id = req["params"]["plan_id"]
  let qid = (req["form"]["qid"] ?? "").trim()
  let value = (req["form"]["value"] ?? "").trim()
  if qid == "" or value == ""
    return {"status": 422, "body": "qid and value required"}
  end
  let answer_path = run_state_root() + "/_plans/" + plan_id + "/pending_answer.json"
  Trusted.write(answer_path, JSON.stringify({ "id": qid, "value": value }))
  let state = read_plan_state(plan_id)
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": render_partial("tasks/plan_progress", {
      "project":          project,
      "plan_id":          plan_id,
      "log":              state["log"],
      "status":           state["status"],
      "pending_question": state["pending_question"],
      "prompt":           state["prompt"]
    })
  }
end

# Spawn bin/plan-run in the background and return its plan_id. The
# runner detaches via `nohup … &`, so System.run_sync returns
# immediately rather than blocking the request handler.
#
# `model` and `project_path` must already be validated by their
# respective callers — both are spliced into the shell command line.
# `project_path` comes from `find_project(...)["path"]` (validated by
# Trusted.is_dir) so it can't carry shell metachars.
#
# Persists the chosen model + the source project path to the plan's
# state dir so refine and rehydrate flows know which project the plan
# was about (the agent reads CLAUDE.md / globs *.sl files from there).
fn spawn_plan_agent(notes, model, project_path)
  let nonce = str(DateTime.now().to_unix() rescue 0)
  let plan_id = "plan-" + nonce
  let notes_path = "/tmp/plan-task-" + nonce + ".md"
  Trusted.write(notes_path, notes)
  let dir = run_state_root() + "/_plans/" + plan_id
  System.run_sync(["mkdir", "-p", dir]) rescue null
  Trusted.write(dir + "/model", model) rescue null
  Trusted.write(dir + "/prompt", notes) rescue null
  Trusted.write(dir + "/project_path", project_path) rescue null
  let line = "nohup ./bin/plan-run " + plan_id + " " + notes_path
            + " " + model + " " + project_path
            + " >/dev/null 2>&1 & disown"
  let res = System.run_sync(["bash", "-c", line])
  if res["exit_code"] != 0
    return nil
  end
  plan_id
end

# Allowlist plan-step models. The value reaches a shell command line via
# `spawn_plan_agent`, so we MUST refuse anything that didn't come from
# the dropdown. Two shapes are valid:
#   - Claude SDK ids ("claude-opus-4-7", "claude-sonnet-4-6", ...)
#   - opencode "provider/model" ids whose segments use a narrow charset
# Returns the canonical default when the input doesn't match — never
# raises, never echoes the bad value back.
fn _allow_plan_model(value)
  let v = (value ?? "").trim()
  let claude_allowed = ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
  for a in claude_allowed
    if v == a
      return v
    end
  end
  if _looks_like_opencode_model(v)
    return v
  end
  "claude-sonnet-4-6"
end

# Stitch the form's plan_model with its plan_variant ("low" / "medium" /
# "high" / "minimal" / "max"). Variants only apply to opencode-shape
# models — claude SDK ids ignore the variant. Returns a value that is
# already validated by _allow_plan_model, so the result is safe to
# store and forward to bin/task-run.
fn _stitched_plan_model(form)
  let base    = ((form ?? {})["plan_model"]   ?? "").trim()
  let variant = ((form ?? {})["plan_variant"] ?? "").trim()
  let is_opencode = base.index_of("/") > 0
  if is_opencode and variant != "" and variant != "default" and _matches_charset(variant, "variant")
    return _allow_plan_model(base + ":" + variant)
  end
  return _allow_plan_model(base)
end

# Read the on-disk state for a plan_id. Returns { status, log, body,
# pending_question, model, prompt }. body is read only when
# status=="done"; pending_question is parsed from the JSON file the SDK
# runner writes when the agent calls AskUserQuestion / ExitPlanMode.
# `model` and `prompt` were persisted by `spawn_plan_agent`.
fn read_plan_state(plan_id)
  let dir = run_state_root() + "/_plans/" + plan_id
  let status = read_last_status(dir + "/status")
  let log_text = Trusted.read(dir + "/log") rescue ""
  let body = ""
  if status == "done"
    body = Trusted.read(dir + "/body") rescue ""
  end
  let pending_question = nil
  let pq_text = Trusted.read(dir + "/pending_question.json") rescue ""
  if pq_text != ""
    pending_question = JSON.parse(pq_text) rescue nil
  end
  let model  = (Trusted.read(dir + "/model") rescue "").trim()
  let prompt = (Trusted.read(dir + "/prompt") rescue "")
  { "status":           status,
    "log":              log_text,
    "body":             body,
    "pending_question": pending_question,
    "model":            model == "" ? "claude-sonnet-4-6" : model,
    "prompt":           prompt }
end

fn read_last_status(path)
  let txt = (Trusted.read(path) rescue "").trim()
  if txt == ""
    return "starting"
  end
  let lines = txt.split("\n")
  let last_line = lines[lines.length - 1].trim()
  let parts = last_line.split("\t")
  parts[parts.length - 1]
end

# Returns nil if the task is within its daily AND weekly cap for the
# effective agent, otherwise a hash describing the breach:
#   { "agent": "claude", "window": "day", "used": N, "cap": M }
# A cap of 0 means unlimited (the dashboard convention) — that branch
# always returns within-limit.
fn _queue_limit_denial(task)
  let agent = Task.effective_agent(task)
  let daily_cap  = Setting.get_or("limit_daily_"  + agent, 0)
  let weekly_cap = Setting.get_or("limit_weekly_" + agent, 0)
  if daily_cap > 0
    let used_day = Task.usage_by_agent("day")[agent] ?? 0
    if used_day >= daily_cap
      return { "agent": agent, "window": "day",
               "used": used_day, "cap": daily_cap }
    end
  end
  if weekly_cap > 0
    let used_week = Task.usage_by_agent("week")[agent] ?? 0
    if used_week >= weekly_cap
      return { "agent": agent, "window": "week",
               "used": used_week, "cap": weekly_cap }
    end
  end
  return nil
end

# Build the 422 response for a denied queue. HTMX requests get an
# inline error fragment that renders inside the existing `#board`
# target; plain form posts get a plain text 422 the browser shows
# directly.
fn _queue_limit_response(req, project, denied)
  let msg = "agent " + denied["agent"] + " is at its " +
            denied["window"] + " limit (" +
            str(denied["used"]) + "/" + str(denied["cap"]) +
            "). Adjust caps in /settings."
  if req["headers"]["hx-request"] == "true"
    let columns = Task.board_for(project["name"])
    let active = "todo"
    return {
      "status": 422,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": render_partial("projects/board", {
        "project": project,
        "columns": columns,
        "indicators": indicators_for(project["name"], columns),
        "agents": agents_for(columns),
        "statuses": Task.kanban_statuses(),
        "active_tab": active,
        "limit_error": msg
      })
    }
  end
  return {"status": 422, "body": msg}
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
        "agents": agents_for(columns),
        "statuses": Task.kanban_statuses(),
        "active_tab": active
      })
    }
  end
  redirect("/projects/" + project["name"])
end
