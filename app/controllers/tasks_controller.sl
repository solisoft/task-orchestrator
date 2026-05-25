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
    let probe = Plan.find_by_plan_id(plan_id)
    if probe != nil
      plan_state = read_plan_state(plan_id)
      if plan_state["status"] == "done"
        plan_title = parse_title_from_body(plan_state["body"])
      end
    end
  end
  # `current` for the picker depends on which stage the view renders:
  #   - plan_state done → planned_body partial preselects state["model"]
  #   - otherwise        → fresh form preselects the global default
  # `Plan.filter_allowed` always keeps `current` in the option list, so a
  # previously persisted choice never silently disappears even if it's
  # no longer on the allowlist.
  let default_model = Setting.get_or("plan_model", "claude-sonnet-4-6")
  let picker_current = (plan_state != nil and plan_state["status"] == "done")
                       ? (plan_state["model"] ?? default_model)
                       : default_model
  let picker = plan_model_picker_data(picker_current)
  render("tasks/new", {
    "title":              "New task — " + project["name"],
    "project":            project,
    "task":               null,
    "plan_id":            plan_id == "" ? nil : plan_id,
    "plan_state":         plan_state,
    "plan_title":         plan_title,
    "default_plan_model": default_model,
    "claude_options":     picker["claude_options"],
    "opencode_options":   picker["opencode_options"],
    "theme": Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class": Setting.current_theme_class()
  })
end

# Pre-compute the locals the `features/plan_model_select` partial needs.
# Built purely from the DB allowlist — never shells out to opencode.
# View templates can't resolve model classes, so the partitioning into
# Claude vs opencode happens here and is threaded into render() as
# `claude_options` / `opencode_options`. The settings page is the only
# caller that needs the full unfiltered opencode universe; it calls
# `list_opencode_models()` directly to render the allowlist panel.
fn plan_model_picker_data(current)
  let allow      = Plan.allowed_model_ids()
  let claude_all = Plan.claude_model_ids()
  let labels     = Plan.claude_model_labels()
  let claude_set = {}
  for c in claude_all
    claude_set[c] = true
  end
  let claude_ids   = []
  let opencode_ids = []
  let codex_ids    = []
  for id in allow
    if claude_set[id] == true
      claude_ids.push(id)
    elsif id.starts_with("codex/")
      codex_ids.push(id)
    else
      opencode_ids.push(id)
    end
  end
  if allow.length() == 0
    claude_ids = claude_all
  end
  let cur = (current ?? "").trim()
  if cur != ""
    let seen = false
    for c in claude_ids
      if c == cur
        seen = true
      end
    end
    for o in opencode_ids
      if o == cur
        seen = true
      end
    end
    for cx in codex_ids
      if cx == cur
        seen = true
      end
    end
    if not seen
      if claude_set[cur] == true
        claude_ids.push(cur)
      elsif cur.starts_with("codex/")
        codex_ids.push(cur)
      else
        opencode_ids.push(cur)
      end
    end
  end
  let claude_opts = []
  for id in claude_ids
    claude_opts.push({ "id": id, "label": labels[id] ?? id })
  end
  {
    "claude_options":   claude_opts,
    "opencode_options": opencode_ids,
    "codex_options":    codex_ids
  }
end

# Shell out to `opencode models`, return the (possibly empty) list of
# `provider/model` strings. Cached in the Setting table for 5 minutes so
# we don't pay the shell exec on every page load. The cache reflects
# whatever opencode currently has configured — providers come and go,
# but not faster than the TTL.
fn list_opencode_models()
  let cached = Setting.get_or("opencode_models_cache", nil)
  if cached != nil
    let age = (cached["_cached_at"] ?? 0)
    if DateTime.now().to_unix() - age < 300
      return cached["models"] ?? []
    end
  end
  let res = System.run_sync(["opencode", "models"]) rescue nil
  if res == nil or res["exit_code"] != 0
    return []
  end
  let lines = (res["stdout"] ?? "").split("\n")
  let out = []
  for line in lines
    let s = line.trim()
    if _looks_like_opencode_model(s)
      out.push(s)
    end
  end
  Setting.set("opencode_models_cache", { "_cached_at": DateTime.now().to_unix(), "models": out })
  out
end

fn list_codex_models()
  let cached = Setting.get_or("codex_models_cache", nil)
  if cached != nil
    let age = (cached["_cached_at"] ?? 0)
    if DateTime.now().to_unix() - age < 300
      return cached["models"] ?? []
    end
  end
  let res = System.run_sync(["codex", "models"]) rescue nil
  if res == nil or res["exit_code"] != 0
    return []
  end
  let lines = (res["stdout"] ?? "").split("\n")
  let out = []
  for line in lines
    let s = line.trim()
    if s.length() > 0
      out.push("codex/" + s)
    end
  end
  Setting.set("codex_models_cache", { "_cached_at": DateTime.now().to_unix(), "models": out })
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
  # Read via `req["all"]` (route + query + form + JSON merged) so the
  # same code path works for both production htmx form posts and the
  # test client, which sends JSON. Matches the convention in plan_answer.
  let form = req["all"] ?? {}
  let body = form["body_md"] ?? ""
  let title = (form["title"] ?? "").trim()
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
  let model = _stitched_plan_model(form)
  # Task routes run outside the auth middleware scope (so `task-queue`
  # and the dispatcher can hit them without a session), so we read the
  # changing user directly from the session cookie instead of relying
  # on `req["current_user"]`.
  let author = session_get("user_email") ?? ""
  let task = Task.create({
    "_key":    Task.key_for(project["name"], slug),
    "project": project["name"],
    "slug":    slug,
    "title":   title,
    "body_md": body,
    "model":   model,
    "author":  author,
    "status":  "todo"
  })
  if task._errors
    return render("tasks/new", {
      "title": "New task — " + project["name"],
      "project": project,
      "task": task,
      "theme": Setting.current_theme(),
      "theme_css_vars": Setting.current_theme_css_vars(),
      "theme_class": Setting.current_theme_class()
    })
  end
  # Tasks created from a plan carry the originating plan_id in a hidden
  # form input — stamp it onto the Plan so /plans can surface a "linked
  # task" badge. A missing plan_id (manual create) or unknown plan_id
  # (stale form) is silently ignored: the task creation itself succeeded.
  let plan_id = (form["plan_id"] ?? "").trim()
  if plan_id != ""
    let plan = Plan.find_by_plan_id(plan_id)
    if plan != nil
      plan.task_slug = task.slug
      plan.save()
    end
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
end

# POST /api/projects/:name/tasks — JSON-in / JSON-out endpoint for
# agent-driven task creation. Sits behind `middleware("api_key", ...)`
# so it can be hit without a session cookie. The body shape is:
#   { "title": "...", "body_md": "...", "model": "..."(optional),
#     "author": "..."(optional) }
# Either `title` or a leading `# heading` line in `body_md` is required;
# `_allow_plan_model` validates `model` so anything outside the
# allowlist falls back to the canonical default.
fn api_create(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return _api_tasks_json(404, { "error": "Unknown project: " + (req["params"]["name"] ?? "") })
  end
  let body = req["json"] ?? req["all"] ?? {}
  let body_md = body["body_md"] ?? ""
  let title = (body["title"] ?? "").trim()
  if title == ""
    title = parse_title_from_body(body_md)
  end
  if title == ""
    return _api_tasks_json(422, {
      "error": "title is required (provide `title` or a `# heading` line in `body_md`)"
    })
  end
  let slug = unique_slug_for(project["name"], title.slugify())
  let model = _allow_plan_model((body["model"] ?? "").trim())
  let author = (body["author"] ?? "agent").trim()
  let task = Task.create({
    "_key":    Task.key_for(project["name"], slug),
    "project": project["name"],
    "slug":    slug,
    "title":   title,
    "body_md": body_md,
    "model":   model,
    "author":  author,
    "status":  "todo"
  })
  if task._errors
    return _api_tasks_json(422, { "error": "validation failed", "details": task._errors })
  end
  let url = "/projects/" + project["name"] + "/tasks/" + task.slug
  return _api_tasks_json(201, { "slug": task.slug, "url": url })
end

# Build a JSON response with the conventional Content-Type. Kept local
# to this controller so the action's failure modes stay consistent
# (every branch returns the same shape).
fn _api_tasks_json(status, payload)
  return {
    "status":  status,
    "headers": { "Content-Type": "application/json; charset=utf-8" },
    "body":    JSON.stringify(payload)
  }
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
  # Pre-compute the model-picker locals for todo tasks so the Queue and
  # Save forms can let the user pick a model before enqueuing. View
  # scope can't resolve Plan.X, so the partitioning has to happen here.
  let default_model = Setting.get_or("plan_model", "claude-sonnet-4-6")
  let picker_current = (task.model ?? "") == "" ? default_model : task.model
  let picker = plan_model_picker_data(picker_current)
  # Pre-load past code reviews for the panel's history list. View scope
  # can't resolve `CodeReview.X`, so we materialise them here. Empty
  # array when the task hasn't been reviewed yet.
  let code_reviews = []
  if task.status == "review"
    code_reviews = CodeReview.for_task(project["name"], task.slug)
  end
  render("tasks/show", {
    "title": task.slug,
    "project": project,
    "task": task,
    "branch_info": _branch_info_for(task, project),
    "can_commit_push": _can_commit_push(task, project),
    "default_plan_model":   default_model,
    "default_review_model": Plan.default_review_model(),
    "claude_options":     picker["claude_options"],
    "opencode_options":   picker["opencode_options"],
    "code_reviews":       code_reviews,
    "flash_error":        nil,
    "theme": Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class": Setting.current_theme_class()
  })
end

# GET /projects/:name/tasks/:slug/code-review — htmx fetch that returns
# just the code-review panel partial. Used after a WS terminal frame
# fires `reload: true` so the spinner is swapped out for the completed
# history entry without a full page navigation.
fn code_review_panel(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  let _pkr = _picker_locals_for(task)
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": render_partial("tasks/code_review", {
      "project":            project,
      "task":               task,
      "default_plan_model": _pkr["default_plan_model"],
      "claude_options":     _pkr["claude_options"],
      "opencode_options":   _pkr["opencode_options"],
      "reviews":            CodeReview.for_task(project["name"], task.slug)
    })
  }
end

# GET /projects/:name/tasks/:slug/sidebar — returns the task as an HTML
# fragment for the feature page's right-side sidebar overlay. No layout,
# no chrome — just the contents of `tasks/_sidebar` so HTMX can swap it
# into `#task-sidebar-body` without a full navigation.
fn sidebar(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found: " + req["params"]["slug"]}
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": render_partial("tasks/sidebar", {
      "project": project,
      "task":    task
    })
  }
end

# Hash describing the per-task git branch for the merge / checkout UI on
# the task page, or nil when the task isn't a candidate ("inprogress",
# "review" or "done"). Both local-branch and PR-mode tasks get a panel:
# PR-mode just hides the Merge button (the PR is the merge path). The
# `is_local_branch` flag lets the view make that call. Returns:
#   { "name": "task/<slug>", "main": "main"|"master",
#     "exists": Bool, "merged": Bool, "worktree_path": String|nil,
#     "is_local_branch": Bool }
fn _branch_info_for(task, project)
  if task.status != "inprogress" and task.status != "review" and task.status != "done"
    return nil
  end
  let branch_name = task_branch_name(task.slug)
  let project_path = project["path"]
  let exists_in_project = task_branch_exists(project_path, task.slug)
  let wt_path = run_worktree_path(project["name"], task.slug)
  let wt_exists = run_worktree_exists(project["name"], task.slug)
  let exists_in_worktree = wt_exists and task_worktree_branch_exists(project["name"], task.slug)
  let exists = exists_in_project or exists_in_worktree
  {
    "name":   branch_name,
    "main":   project_main_branch(project_path),
    "exists": exists,
    "merged": task_branch_merged(project_path, task.slug),
    "worktree_path": exists_in_worktree ? wt_path : nil,
    "is_local_branch": task.outcome == "local-branch"
  }
end

fn _can_commit_push(task, project)
  if task.status != "review"
    return false
  end
  if task.pr_url == nil or task.pr_url == ""
    return false
  end
  if not run_worktree_exists(project["name"], task.slug)
    return false
  end
  let worktree_path = run_worktree_path(project["name"], task.slug)
  project_worktree_dirty(worktree_path)
end

# POST /projects/:name/tasks/:slug/merge — merge the per-task branch
# into the project's main branch. Only valid for `inprogress`, `review`
# or `done` tasks whose outcome was `local-branch` (no PR was opened).
# The merge itself is guarded by `merge_task_branch` (refuses to switch
# branches or run on a dirty tree).
fn merge_branch(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  if task.status != "inprogress" and task.status != "review" and task.status != "done" or task.outcome != "local-branch"
    return {"status": 422,
            "body": "merge is only available for inprogress/review/done tasks with a local branch"}
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

fn checkout_branch(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  if task.status != "inprogress" and task.status != "review" and task.status != "done"
    return {"status": 422,
            "body": "checkout is only available for inprogress/review/done tasks"}
  end
  if not task_branch_exists(project["path"], task.slug)
    return {"status": 422,
            "body": "branch " + task_branch_name(task.slug) + " not found in " +
                    project["path"]}
  end
  let wt_path = run_worktree_path(project["name"], task.slug)
  if Trusted.is_dir(wt_path) and task_worktree_branch_exists(project["name"], task.slug)
    return {"status": 422,
            "body": "branch is checked out in worktree " + wt_path + " — cd in directly"}
  end
  let current = project_current_branch(project["path"])
  if current == task_branch_name(task.slug)
    return redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
  end
  let res = System.run_sync([
    "git", "-C", project["path"],
    "checkout", task_branch_name(task.slug)
  ])
  if res["exit_code"] != 0
    return {"status": 422,
            "body": "checkout failed: " + (res["stderr"] ?? "unknown error")}
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
  let force = (req["all"] ?? {})["force"]
  if task.pr_url != nil and task.pr_url != ""
    if not force and not pr_merged(task.pr_url)
      return {"status": 422, "body": "PR not merged"}
    end
  end
  task.change_author = _current_changer(req)
  task.status = "done"
  task.finished_at = DateTime.now().to_iso()
  task.save()
  if task._errors
    return {"status": 422, "body": "Save failed"}
  end
  Feature.refresh_for_task(task)
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
end

fn commit_push(req)
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
            "body": "commit-push is only available for review tasks (current: " +
                    task.status + ")"}
  end
  if task.pr_url == nil or task.pr_url == ""
    return {"status": 422,
            "body": "commit-push is only available for tasks with an open PR"}
  end
  if not run_worktree_exists(project["name"], task.slug)
    return {"status": 422,
            "body": "worktree not found — task may not have been run yet"}
  end
  let worktree_path = run_worktree_path(project["name"], task.slug)
  let result = commit_and_push(worktree_path, task.slug)
  if not result["ok"]
    let err = result["error"]
    let picker = plan_model_picker_data(Setting.get_or("plan_model", "claude-sonnet-4-6"))
    let code_reviews = CodeReview.for_task(project["name"], task.slug)
    return render("tasks/show", {
      "title": task.slug,
      "project": project,
      "task": task,
      "branch_info": _branch_info_for(task, project),
      "can_commit_push": _can_commit_push(task, project),
      "default_plan_model":   Setting.get_or("plan_model", "claude-sonnet-4-6"),
      "default_review_model": Plan.default_review_model(),
      "claude_options":     picker["claude_options"],
      "opencode_options":   picker["opencode_options"],
      "code_reviews":       code_reviews,
      "flash_error":        err,
      "theme": Setting.current_theme(),
      "theme_css_vars": Setting.current_theme_css_vars(),
      "theme_class": Setting.current_theme_class()
    })
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
end

fn react(req)
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
            "body": "react is only available for review tasks (current: " +
                    task.status + ")"}
  end
  if task.pr_url == nil or task.pr_url == ""
    return {"status": 422,
            "body": "react is only available for tasks with an open PR"}
  end
  let prompt = (req["form"]["prompt"] ?? "").trim()
  if prompt == ""
    return {"status": 422, "body": "Prompt is required"}
  end
  task.status = "inprogress"
  task.save()
  let nonce = str(DateTime.now().to_unix() rescue 0)
  let prompt_path = "/tmp/react-prompt-" + nonce + ".md"
  Trusted.write(prompt_path, prompt)
  let line = "nohup ./bin/react-run " + project["name"] + " " +
             task.slug + " " + prompt_path +
             " >/dev/null 2>&1 & disown"
  let res = System.run_sync(["bash", "-c", line])
  if res["exit_code"] != 0
    return {"status": 500, "body": "Failed to spawn react agent — check server log"}
  end
  if req["headers"]["hx-request"] == "true"
    let _pkr = _picker_locals_for(task)
    return {
      "status": 200,
      "headers": { "Content-Type": "text/html; charset=utf-8" },
      "body": render_partial("tasks/code_review", {
        "project":            project,
        "task":               task,
        "default_plan_model": _pkr["default_plan_model"],
        "claude_options":     _pkr["claude_options"],
        "opencode_options":   _pkr["opencode_options"],
        "reviews":            CodeReview.for_task(project["name"], task.slug)
      })
    }
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug + "/run")
end

# POST /projects/:name/tasks/:slug/code-review — spawn the /review-task
# skill against the task's existing worktree using the chosen model.
# The agent appends to the run log so the user can watch the transcript
# on the run page. The worktree must already exist (the task was run);
# we never recreate it here — the review must execute against the same
# tree /do-task and /review-task already left in place.
fn code_review(req)
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
            "body": "code-review is only available for review tasks (current: " +
                    task.status + ")"}
  end
  # Allow code-review when EITHER the worktree still exists (in-place
  # review of /do-task's working tree) OR the task has a `pr_url` (PR
  # diff review on GitHub). `bin/review-run` chooses the mode based on
  # what's available at runtime.
  let has_worktree = run_worktree_exists(project["name"], task.slug)
  let has_pr = (task.pr_url ?? "") != ""
  if not has_worktree and not has_pr
    return {"status": 422,
            "body": "code-review needs either a local worktree or a PR — task has neither"}
  end
  # `_stitched_plan_model` validates the picker output against the
  # allowlist, so the value is safe to splice into the shell command.
  let model = _stitched_plan_model(req["all"] ?? {})
  # Create the audit row up front so the WS handler has something to
  # find as soon as the page swap lands. `bin/review-run` writes status
  # / log / body back into this same row via its review_id.
  let review_id = "rev-" + str(DateTime.now().to_unix() rescue 0)
  let review = CodeReview.create({
    "_key":      CodeReview.key_for(project["name"], task.slug, review_id),
    "project":   project["name"],
    "slug":      task.slug,
    "review_id": review_id,
    "task_key":  task._key,
    "status":    "starting",
    "log":       "",
    "body":      "",
    "model":     model,
    "pending":   false
  })
  if review._errors
    return {"status": 500, "body": "Failed to create review row"}
  end
  let line = "nohup ./bin/review-run " + project["name"] + " " +
             task.slug + " " + model + " " + review_id +
             " >/dev/null 2>&1 & disown"
  let res = System.run_sync(["bash", "-c", line])
  if res["exit_code"] != 0
    return {"status": 500, "body": "Failed to spawn review agent — check server log"}
  end
  # HTMX requests get the panel fragment back in-place (no redirect),
  # so the spinner appears without leaving the task page. Direct POST
  # without the HX-Request header still falls back to a redirect so
  # the action stays usable from curl / non-htmx clients.
  if req["headers"]["hx-request"] == "true"
    let _pkr = _picker_locals_for(task)
    return {
      "status": 200,
      "headers": { "Content-Type": "text/html; charset=utf-8" },
      "body": render_partial("tasks/code_review", {
        "project":            project,
        "task":               task,
        "default_plan_model": _pkr["default_plan_model"],
        "claude_options":     _pkr["claude_options"],
        "opencode_options":   _pkr["opencode_options"],
        "reviews":            CodeReview.for_task(project["name"], task.slug)
      })
    }
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
end

# WebSocket handler for the code-review panel. The client opens a
# socket per running review and ticks until status is terminal; on
# `reload: true` it triggers a panel re-fetch so the spinner is
# replaced with the completed history entry. Mirrors the protocol used
# by runs#stream / tasks#plan_stream.
fn code_review_stream(event)
  let event_type = event["type"]
  if event_type != "message"
    return {}
  end
  let raw = (event["message"] ?? "").trim()
  let parsed = JSON.parse(raw) rescue nil
  if parsed == nil
    return { "send": JSON.stringify({ "event": "error", "message": "bad message", "terminal": true }) }
  end
  let review_id = (parsed["review_id"] ?? "").trim()
  let offset = parsed["offset"] ?? 0
  let frame_kind = parsed["type"] == "subscribe" ? "connect" : "message"
  let data = code_review_stream_payload(review_id, frame_kind, offset)
  if data["event"] == "error"
    return { "send": JSON.stringify(data) }
  end
  { "send": JSON.stringify(data) }
end

# Helper: package the locals the code-review partial needs (model
# picker options + global default) so both `code_review` and `show`
# can hand the partial the same shape.
fn _picker_locals_for(task)
  let saved = (task.model ?? "").trim()
  let picker = plan_model_picker_data(saved)
  {
    "claude_options":     picker["claude_options"],
    "opencode_options":   picker["opencode_options"],
    "default_plan_model": Plan.default_plan_model()
  }
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
  # Read via `req["all"]` (route + query + form + JSON merged) so the
  # same code path works for production htmx form posts and the test
  # client (which sends JSON).
  let form = req["all"] ?? {}
  task.body_md = form["body_md"] ?? ""
  let title = (form["title"] ?? "").trim()
  if title != ""
    task.title = title
  end
  # Persist the model picker choice when the form carries one — lets the
  # user pre-save a model before clicking Queue. Skipped when absent so
  # callers that POST a partial form don't clobber an existing choice.
  let raw_model = (form["plan_model"] ?? "").trim()
  if raw_model != ""
    task.model = _stitched_plan_model(form)
  end
  task.save()
  if task._errors
    return render("tasks/show", {
      "title": task.slug,
      "project": project,
      "task": task,
      "theme": Setting.current_theme(),
      "theme_css_vars": Setting.current_theme_css_vars(),
      "theme_class": Setting.current_theme_class()
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
  # Pick-model-and-queue in one step: when the Queue form posts a
  # `plan_model` field, persist it before the limit check so the
  # effective-agent budget is computed against the chosen model.
  let form = req["all"] ?? {}
  let queue_model = (form["plan_model"] ?? "").trim()
  if queue_model != ""
    task.model = _stitched_plan_model(form)
    task.save()
    if task._errors
      return {"status": 422, "body": "Save failed"}
    end
  end
  let denied = _queue_limit_denial(task)
  if denied != nil
    return _queue_limit_response(req, project, denied)
  end
  let changer = _current_changer(req)
  move_response(req, fn(t) {
    t.change_author = changer
    t.queue!()
  })
end

fn unqueue(req)
  let changer = _current_changer(req)
  move_response(req, fn(t) {
    t.change_author = changer
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

# WebSocket handler for the live plan-task agent transcript.
#
# Mirrors `runs#stream`: client opens the socket, sends `tick` frames
# with its byte cursor, server replies with `delta` frames carrying the
# new bytes since that cursor plus a re-rendered status + question
# fragment. On a terminal status (done / failed) we set `reload: true`
# so the client re-fetches `/tasks/new?plan_id=...`, letting the
# controller render the planned-body view in place of #form-stage.
#
# Suppression around the awaiting_question state is enforced on the
# client side (it stops sending ticks while the question card is up,
# so the agent's pollAnswer loop never races the user's click) — but
# we also defensively don't push log bytes when `has_question` is true.
fn plan_stream(event)
  let event_type = event["type"]
  if event_type != "message"
    return {}
  end
  let raw = (event["message"] ?? "").trim()
  let parsed = JSON.parse(raw) rescue nil
  if parsed == nil
    return { "send": JSON.stringify({ "event": "error", "message": "bad message", "terminal": true }) }
  end
  let plan_id = (parsed["plan_id"] ?? "").trim()
  let project_name = (parsed["project"] ?? "").trim()
  let project = find_project(project_name) rescue nil
  if project == nil
    return { "send": JSON.stringify({ "event": "error", "message": "unknown project", "terminal": true }) }
  end
  let offset = parsed["offset"] ?? 0
  let frame_kind = parsed["type"] == "subscribe" ? "connect" : "message"
  let data = plan_stream_payload(plan_id, frame_kind, offset)
  if data["event"] == "error"
    return { "send": JSON.stringify(data) }
  end
  let pq = data["pending_question"]
  data["status_html"] = render_partial("tasks/plan_status", {
    "plan_id":          plan_id,
    "status":           data["status"],
    "pending_question": pq
  })
  data["question_html"] = render_partial("tasks/plan_question", {
    "project":          project,
    "plan_id":          plan_id,
    "pending_question": pq
  })
  { "send": JSON.stringify(data) }
end

# HTMX poll endpoint for the in-flight plan agent. Returns ONLY the
# right-panel `_plan_stream` partial (root id `plan-stream`), so the
# 2-second poll never re-renders the static prompt aside on the left.
# When the runner has flagged status=done, returns the full planned-body
# replacement and uses HX-Retarget/HX-Reswap so htmx swaps the whole
# `#form-stage` instead of just `#plan-stream`. Polling stops automatically
# because the planned-body partial doesn't carry hx-* attrs.
fn plan_log(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let plan_id = req["params"]["plan_id"]
  let state = read_plan_state(plan_id)
  if state["status"] == "done"
    let title  = parse_title_from_body(state["body"])
    let picker = plan_model_picker_data(state["model"] ?? "")
    return {
      "status": 200,
      "headers": {
        "Content-Type": "text/html; charset=utf-8",
        "HX-Retarget":  "#form-stage",
        "HX-Reswap":    "innerHTML"
      },
      "body": render_partial("tasks/planned_body", {
        "project":          project,
        "plan_id":          plan_id,
        "body":             state["body"],
        "title":            title,
        "model":            state["model"],
        "claude_options":   picker["claude_options"],
        "opencode_options": picker["opencode_options"]
      })
    }
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": render_partial("tasks/plan_stream", {
      "project":          project,
      "plan_id":          plan_id,
      "log":              state["log"],
      "status":           state["status"],
      "pending_question": state["pending_question"]
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

# Re-spawn a failed plan using the original prompt + model. Issued by
# the "Try again" button on the failed _plan_stream panel. Allocates a
# NEW plan_id so the failed plan stays in the index for diagnosis.
fn plan_retry(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let prev_plan_id = req["params"]["plan_id"]
  let prev = Plan.find_by_plan_id(prev_plan_id)
  if prev == nil
    return {"status": 404, "body": "Unknown plan"}
  end
  let notes = (prev.prompt ?? "").trim()
  if notes == ""
    return {"status": 422, "body": "Original prompt missing — cannot retry"}
  end
  let model = _allow_plan_model(prev.model ?? "")
  let plan_id = spawn_plan_agent(notes, model, project["path"])
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
      "prompt":           notes
    })
  }
end

# Read the model the user picked when this plan was first spawned.
# Falls back to the canonical default so a missing/corrupt file never
# raises into the refine flow.
fn _read_plan_model(plan_id)
  let plan = Plan.find_by_plan_id(plan_id)
  if plan == nil
    return "claude-sonnet-4-6"
  end
  let v = (plan.model ?? "").trim()
  if v == ""
    return "claude-sonnet-4-6"
  end
  v
end

fn plan_answer(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let plan_id = req["params"]["plan_id"]
  # Read via `req["all"]` (route + query + form + JSON merged) so the
  # same code path works for both production htmx form posts and the
  # test client, which sends JSON. `req["form"]` alone would miss tests;
  # `req["json"]` alone would miss prod.
  let body_params = req["all"] ?? {}
  let qid = (body_params["qid"] ?? "").trim()
  let value = (body_params["value"] ?? "").trim()
  if qid == "" or value == ""
    return {"status": 422, "body": "qid and value required"}
  end
  let plan = Plan.find_by_plan_id(plan_id)
  if plan != nil
    plan.write_pending_answer(qid, value)
  end
  let state = read_plan_state(plan_id)
  # Mirror plan_log: while running, return only the right panel so the
  # left prompt aside is preserved across answer round-trips. If the
  # answer raced the agent finishing, retarget to #form-stage so the
  # planned-body view replaces the whole stage.
  if state["status"] == "done"
    let title  = parse_title_from_body(state["body"])
    let picker = plan_model_picker_data(state["model"] ?? "")
    return {
      "status": 200,
      "headers": {
        "Content-Type": "text/html; charset=utf-8",
        "HX-Retarget":  "#form-stage",
        "HX-Reswap":    "innerHTML"
      },
      "body": render_partial("tasks/planned_body", {
        "project":          project,
        "plan_id":          plan_id,
        "body":             state["body"],
        "title":            title,
        "model":            state["model"],
        "claude_options":   picker["claude_options"],
        "opencode_options": picker["opencode_options"]
      })
    }
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": render_partial("tasks/plan_stream", {
      "project":          project,
      "plan_id":          plan_id,
      "log":              state["log"],
      "status":           state["status"],
      "pending_question": state["pending_question"]
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
  plan_write_notes(notes_path, notes)
  let project = ""
  if project_path != nil and project_path != ""
    let segs = project_path.split("/")
    if segs.length() > 0
      project = segs[segs.length() - 1]
    end
  end
  # stream_token gates the /ws/feature-generate-stream WS route to prevent
  # anonymous callers from reading a feature plan's transcript. The token is
  # random and per-plan; it is rendered into the show page (server-rendered,
  # auth-gated) and echoed back on every WS tick. plan-stream / run-stream
  # do not use this field (their HTTP counterparts are already public).
  let token_nonce = str(DateTime.now().to_unix_millis() rescue 0) + "-" + str(Math.random() * 1000000 rescue 0)
  let plan = Plan.create({
    "_key":          plan_id,
    "project":       project,
    "plan_id":       plan_id,
    "status":        "starting",
    "model":         model,
    "prompt":        notes,
    "project_path":  project_path,
    "body":          "",
    "log":           "",
    "pending_question": nil,
    "zombie":        false,
    "stream_token":  token_nonce
  })
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

# `read_plan_state(plan_id)` lives in `app/models/plan.sl` so the WS
# stream handlers and the spec suite can both call it without going
# through HTTP. This module reaches for it as a free-standing function
# (auto-loaded with the model file at server boot).

fn archive(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  if task.status != "todo" and task.status != "done" and task.status != "failed"
    return {"status": 422,
            "body": "archive is only available for todo, done, or failed tasks " +
                    "(current: " + task.status + ")"}
  end
  task.change_author = _current_changer(req)
  task.status = "archived"
  task.save()
  if task._errors
    return {"status": 422, "body": "Save failed"}
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
end

fn unarchive(req)
  let project = find_project(req["params"]["name"])
  if project == nil
    return {"status": 404, "body": "Unknown project"}
  end
  let task = Task.find_by_slug(project["name"], req["params"]["slug"])
  if task == nil
    return {"status": 404, "body": "Task not found"}
  end
  if task.status != "archived"
    return {"status": 422,
            "body": "unarchive is only available for archived tasks (current: " +
                    task.status + ")"}
  end
  task.change_author = _current_changer(req)
  task.status = "todo"
  task.finished_at = null
  task.save()
  if task._errors
    return {"status": 422, "body": "Save failed"}
  end
  redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
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
        "totals": totals_for(project["name"], columns),
        "agents": agents_for(columns),
        "statuses": Task.kanban_statuses(),
        "active_tab": active,
        "limit_error": msg
      })
    }
  end
  return {"status": 422, "body": msg}
end

# Resolve the email of the user driving the current request. Task
# routes run outside the auth middleware scope, so `req["current_user"]`
# is always nil — we fall back to the raw session cookie via
# `session_get`. Returns "" for unauthenticated requests (background
# agents, the dispatcher) so the ActivityLog row still gets stamped
# with a known-empty changer rather than failing the save.
fn _current_changer(req)
  let user = req["current_user"] rescue nil
  if user != nil
    return user.email ?? ""
  end
  return session_get("user_email") ?? ""
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
        "totals": totals_for(project["name"], columns),
        "agents": agents_for(columns),
        "statuses": Task.kanban_statuses(),
        "active_tab": active
      })
    }
  end
  redirect("/projects/" + project["name"])
end
