# Task viewer + queue/save/new actions. All persistence goes through
# `Task < Model` (solidb-backed). The `.md` files in `tasks/<status>/`
# are no longer the source of truth — they're historical artefacts.
class TasksController < ApplicationController
  title: Any
  project: Any
  task: Any
  feature: Any
  default_plan_model: Any
  default_review_model: Any
  claude_options: Any
  opencode_options: Any
  branch_info: Any
  can_commit_push: Any
  code_reviews: Any
  flash_error: Any
  has_run: Any
  slug: Any
  status: Any
  pr_url: Any
  tail: Any
  log_size: Any
  todos: Any

  def new(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {
        "status": 404,
        "body": "Unknown project: " + req["params"]["name"]
      }
    end

    # Phase 5: the standalone planner is gone — `/projects/:name/tasks/new`
    # is now a plain title+body form. Feature briefs are the planning
    # surface (see /features/<id>/generate_tasks).
    default_model = Setting.get_or("plan_model", "claude-sonnet-4-6")
    picker = plan_model_picker_data(default_model)
    @title = "New task — " + project["name"]
    @project = project
    @task = null
    @default_plan_model = default_model
    @claude_options = picker["claude_options"]
    @opencode_options = picker["opencode_options"]
    render("tasks/new")
  end

  def create(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    # Read via `req["all"]` (route + query + form + JSON merged) so the
    # same code path works for both production htmx form posts and the
    # test client, which sends JSON. Matches the convention in plan_answer.
    form = req["all"] ?? {}
    body = form["body_md"] ?? ""
    title = (form["title"] ?? "").trim()
    # Title falls back to the body's first `# ...` heading; slug is derived
    # from the title (lowercased + dashed). Collisions append `-2`, `-3`, …
    # so the user never has to think about the URL piece.
    title = this._parse_title_from_body(body) if title == ""
    if title == ""
      return {"status": 422, "body": "Need a title (or a `# heading` line in the body)"}
    end

    slug = this._unique_slug_for(project["name"], title.slugify())
    # Persist the model the user picked on the new-task form so /do-task
    # runs through the same agent they chose for planning. _allow_plan_model
    # already validates against the SDK allowlist + the opencode shape,
    # so the value is safe to store and forward to bin/task-run.
    model = _stitched_plan_model(form)
    # Task routes run outside the auth middleware scope (so `task-queue`
    # and the dispatcher can hit them without a session), so we read the
    # changing user directly from the session cookie instead of relying
    # on `req["current_user"]`.
    author = session_get("user_email") ?? ""
    task = Task.create({
      "_key": Task.key_for(project["name"], slug),
      "project": project["name"],
      "slug": slug,
      "title": title,
      "body_md": body,
      "model": model,
      "author": author,
      "status": "todo"
    })
    if task._errors
      _picker = plan_model_picker_data(model == "" ? Setting.get_or("plan_model", "claude-sonnet-4-6") : model)
      @title = "New task — " + project["name"]
      @project = project
      @task = task
      @default_plan_model = model
      @claude_options = _picker["claude_options"]
      @opencode_options = _picker["opencode_options"]
      return render("tasks/new")
    end
    redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
  end

  # Pull the first `# ...` heading line out of a markdown body, with the
  # leading hashes/whitespace stripped. Returns "" if the body has none.
  def _parse_title_from_body(body)
    for line in body.split("\n")
      s = line.trim()
      return s.substring(2, s.length).trim() if s.starts_with("# ") && !s.starts_with("## ")
    end
    ""
  end

  # Append `-N` to `base` until no row in solidb's `tasks` collection
  # has the same (project, slug) pair. Caps at 100 attempts to avoid
  # pathological loops.
  def _unique_slug_for(project_name, base)
    base = "task" if base == ""
    candidate = base
    n = 2
    while Task.find_by_slug(project_name, candidate).present? && n <= 100
      candidate = base + "-" + str(n)
      n = n + 1
    end
    candidate
  end

  def show(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {
        "status": 404,
        "body": "Task not found: " + req["params"]["slug"]
      }
    end

    # Pre-compute the model-picker locals for todo tasks so the Queue and
    # Save forms can let the user pick a model before enqueuing. View
    # scope can't resolve Plan.X, so the partitioning has to happen here.
    default_model = Setting.get_or("plan_model", "claude-sonnet-4-6")
    picker_current = (task.model ?? "") == "" ? default_model : task.model
    picker = plan_model_picker_data(picker_current)
    # Pre-load past code reviews for the panel's history list. View scope
    # can't resolve `CodeReview.X`, so we materialise them here. Empty
    # array when the task hasn't been reviewed yet.
    code_reviews = []
    code_reviews = CodeReview.for_task(project["name"], task.slug) if task.status == "review"
    # Pre-load the live run state when the task has been queued (or is past
    # it) so the run-log panel can render inline on the task page. View
    # scope can't resolve `Run.X`, so the lookups happen here. Skipped for
    # `todo` / `proposed` / `archived` — those tasks have no run yet and
    # the view collapses to a single-column brief.
    run_locals = this._run_locals_for(task, project)
    @title = task.slug
    @project = project
    @task = task
    @feature = this._feature_for_task(task)
    @branch_info = _branch_info_for(task, project)
    @can_commit_push = this._can_commit_push(task, project)
    @default_plan_model = default_model
    @default_review_model = Plan.default_review_model()
    @claude_options = picker["claude_options"]
    @opencode_options = picker["opencode_options"]
    @code_reviews = code_reviews
    @flash_error = nil
    @has_run = run_locals["has_run"]
    @slug = task.slug
    @status = run_locals["status"]
    @pr_url = run_locals["pr_url"]
    @tail = run_locals["tail"]
    @log_size = run_locals["log_size"]
    @todos = run_locals["todos"]
    render("tasks/show")
  end

  # Returns the run-state locals the inlined `runs/log` partial needs, or
  # a hash with `has_run: false` and nils when the task hasn't been queued
  # yet. Centralised so commit_push (which re-renders show) and show share
  # the same shape.
  def _run_locals_for(task, project)
    statuses_with_run = ["queued", "inprogress", "review", "done", "failed"]
    has_run = false
    for s in statuses_with_run
      has_run = true if task.status == s
    end
    return {
      "has_run": false,
      "status": nil,
      "pr_url": nil,
      "tail": nil,
      "log_size": nil,
      "todos": nil
    } if !has_run
    {
      "has_run": true,
      "status": Run.run_current_status(project["name"], task.slug),
      "pr_url": Run.run_pr_url(project["name"], task.slug),
      "tail": Run.run_log_tail(project["name"], task.slug, 16384),
      "log_size": Run.run_log_size(project["name"], task.slug),
      "todos": Run.run_latest_todos(project["name"], task.slug)
    }
  end

  # GET /projects/:name/tasks/:slug/code-review — htmx fetch that returns
  # just the code-review panel partial. Used after a WS terminal frame
  # fires `reload: true` so the spinner is swapped out for the completed
  # history entry without a full page navigation.
  def code_review_panel(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    _pkr = this._picker_locals_for(task)
    {
      "status": 200,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": render_partial(
        "tasks/code_review",
        {
          "project": project,
          "task": task,
          "default_plan_model": _pkr["default_plan_model"],
          "claude_options": _pkr["claude_options"],
          "opencode_options": _pkr["opencode_options"],
          "reviews": CodeReview.for_task(project["name"], task.slug)
        }
      )
    }
  end

  # GET /projects/:name/tasks/:slug/sidebar — returns the task as an HTML
  # fragment for the feature page's right-side sidebar overlay. No layout,
  # no chrome — just the contents of `tasks/_sidebar` so HTMX can swap it
  # into `#task-sidebar-body` without a full navigation.
  def sidebar(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {
        "status": 404,
        "body": "Task not found: " + req["params"]["slug"]
      }
    end

    {
      "status": 200,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": render_partial(
        "tasks/sidebar",
        {"project": project, "task": task}
      )
    }
  end

  # View scope can't resolve `Feature.X`, so callers that render tasks/show
  # pre-load the Feature row here. Returns nil when the task has no
  # feature_slug or the slug points at a deleted feature.
  def _feature_for_task(task)
    fslug = (task.feature_slug ?? "").trim()
    return nil if fslug == ""
    Feature.find_by("_key", fslug)
  end

  def _can_commit_push(task, project)
    return false if task.status != "review"
    return false if task.pr_url.nil? || task.pr_url == ""
    return false if !Run.project_has_remote(project["path"])
    return false if !Run.run_worktree_exists(project["name"], task.slug)
    worktree_path = Run.run_worktree_path(project["name"], task.slug)
    Run.project_worktree_dirty(worktree_path)
  end

  # POST /projects/:name/tasks/:slug/merge — merge the per-task branch
  # into the project's main branch. Only valid for `inprogress`, `review`
  # or `done` tasks whose outcome was `local-branch` (no PR was opened).
  # The merge itself is guarded by `merge_task_branch` (refuses to switch
  # branches or run on a dirty tree).
  def merge_branch(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    eligible_status = task.status == "inprogress" || task.status == "review" || task.status == "done"
    needs_local_branch = task.outcome != "local-branch" && Run.project_has_remote(project["path"])
    if !eligible_status || needs_local_branch
      return {"status": 422, "body": "merge is only available for inprogress/review/done tasks with a local branch"}
    end

    if !Run.task_branch_exists(project["path"], task.slug)
      return {
        "status": 422,
        "body": "branch " + Run.task_branch_name(task.slug) + " not found in " + project["path"]
      }
    end

    result = Run.merge_task_branch(project["path"], task.slug)
    if !result["ok"]
      return {
        "status": 422,
        "body": "merge failed: " + result["error"]
      }
    end

    redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
  end

  def checkout_branch(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    if task.status != "inprogress" && task.status != "review" && task.status != "done"
      return {"status": 422, "body": "checkout is only available for inprogress/review/done tasks"}
    end

    if !Run.task_branch_exists(project["path"], task.slug)
      return {
        "status": 422,
        "body": "branch " + Run.task_branch_name(task.slug) + " not found in " + project["path"]
      }
    end

    wt_path = Run.run_worktree_path(project["name"], task.slug)
    # soli-lint-disable-next-line smell/dangerous-server-builtin
    wt_exists = Trusted.is_dir(wt_path)
    if wt_exists && Run.task_worktree_branch_exists(project["name"], task.slug)
      return {
        "status": 422,
        "body": "branch is checked out in worktree " + wt_path + " — cd in directly"
      }
    end

    current = Run.project_current_branch(project["path"])
    if current == Run.task_branch_name(task.slug)
      return redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
    end

    res = System.run_sync([
      "git",
      "-C",
      project["path"],
      "checkout",
      Run.task_branch_name(task.slug)
    ])
    if res["exit_code"] != 0
      return {
        "status": 422,
        "body": "checkout failed: " + (res["stderr"] ?? "unknown error")
      }
    end

    redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
  end

  def mark_done(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    if task.status != "review"
      return {
        "status": 422,
        "body": "mark-done is only available for review tasks (current: " + task.status + ")"
      }
    end

    force = (req["all"] ?? {})["force"]
    if task.pr_url.present? && task.pr_url != ""
      if !force && !Run.pr_merged(task.pr_url)
        return {"status": 422, "body": "PR not merged"}
      end

    end
    task.change_author = this._current_changer(req)
    task.status = "done"
    task.finished_at = DateTime.now().to_iso()
    task.save()
    if task._errors
      return {"status": 422, "body": "Save failed"}
    end

    Feature.refresh_for_task(task)
    redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
  end

  def commit_push(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    if task.status != "review"
      return {
        "status": 422,
        "body": "commit-push is only available for review tasks (current: " + task.status + ")"
      }
    end

    if task.pr_url.nil? || task.pr_url == ""
      return {"status": 422, "body": "commit-push is only available for tasks with an open PR"}
    end

    if !Run.run_worktree_exists(project["name"], task.slug)
      return {"status": 422, "body": "worktree not found — task may not have been run yet"}
    end

    worktree_path = Run.run_worktree_path(project["name"], task.slug)
    result = Run.commit_and_push(worktree_path, task.slug)
    if !result["ok"]
      picker = plan_model_picker_data(Setting.get_or("plan_model", "claude-sonnet-4-6"))
      run_locals = this._run_locals_for(task, project)
      @title = task.slug
      @project = project
      @task = task
      @feature = this._feature_for_task(task)
      @branch_info = _branch_info_for(task, project)
      @can_commit_push = this._can_commit_push(task, project)
      @default_plan_model = Setting.get_or("plan_model", "claude-sonnet-4-6")
      @default_review_model = Plan.default_review_model()
      @claude_options = picker["claude_options"]
      @opencode_options = picker["opencode_options"]
      @code_reviews = CodeReview.for_task(project["name"], task.slug)
      @flash_error = result["error"]
      @has_run = run_locals["has_run"]
      @slug = task.slug
      @status = run_locals["status"]
      @pr_url = run_locals["pr_url"]
      @tail = run_locals["tail"]
      @log_size = run_locals["log_size"]
      @todos = run_locals["todos"]
      return render("tasks/show")
    end
    redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
  end

  def react(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    if task.status != "review"
      return {
        "status": 422,
        "body": "react is only available for review tasks (current: " + task.status + ")"
      }
    end

    if task.pr_url.nil? || task.pr_url == ""
      return {"status": 422, "body": "react is only available for tasks with an open PR"}
    end

    prompt = (req["form"]["prompt"] ?? "").trim()
    if prompt == ""
      return {"status": 422, "body": "Prompt is required"}
    end

    task.status = "inprogress"
    task.save()
    nonce = str(DateTime.now().to_unix() rescue 0)
    prompt_path = "/tmp/react-prompt-" + nonce + ".md"
    # soli-lint-disable-next-line smell/dangerous-server-builtin
    Trusted.write(prompt_path, prompt)
    line = "nohup ./bin/react-run " + project["name"] + " " + task.slug + " " + prompt_path
    + " >/dev/null 2>&1 & disown"
    res = System.run_sync([
      "bash",
      "-c",
      line
    ])
    if res["exit_code"] != 0
      return {"status": 500, "body": "Failed to spawn react agent — check server log"}
    end

    if req["headers"]["hx-request"] == "true"
      _pkr = this._picker_locals_for(task)
      return {
        "status": 200,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": render_partial(
          "tasks/code_review",
          {
            "project": project,
            "task": task,
            "default_plan_model": _pkr["default_plan_model"],
            "claude_options": _pkr["claude_options"],
            "opencode_options": _pkr["opencode_options"],
            "reviews": CodeReview.for_task(project["name"], task.slug)
          }
        )
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
  def code_review(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    if task.status != "review"
      return {
        "status": 422,
        "body": "code-review is only available for review tasks (current: " + task.status + ")"
      }
    end

    # Allow code-review when EITHER the worktree still exists (in-place
    # review of /do-task's working tree) OR the task has a `pr_url` (PR
    # diff review on GitHub). `bin/review-run` chooses the mode based on
    # what's available at runtime.
    has_worktree = Run.run_worktree_exists(project["name"], task.slug)
    has_pr = (task.pr_url ?? "") != ""
    if !has_worktree && !has_pr
      return {"status": 422, "body": "code-review needs either a local worktree or a PR — task has neither"}
    end

    # `_stitched_plan_model` validates the picker output against the
    # allowlist, so the value is safe to splice into the shell command.
    model = _stitched_plan_model(req["all"] ?? {})
    # Create the audit row up front so the WS handler has something to
    # find as soon as the page swap lands. `bin/review-run` writes status
    # / log / body back into this same row via its review_id.
    review_id = "rev-" + str(DateTime.now().to_unix() rescue 0)
    review = CodeReview.create({
      "_key": CodeReview.key_for(project["name"], task.slug, review_id),
      "project": project["name"],
      "slug": task.slug,
      "review_id": review_id,
      "task_key": task._key,
      "status": "starting",
      "log": "",
      "body": "",
      "model": model,
      "pending": false
    })
    if review._errors
      return {"status": 500, "body": "Failed to create review row"}
    end

    line = "nohup ./bin/review-run " + project["name"] + " " + task.slug + " " + model + " " + review_id
    + " >/dev/null 2>&1 & disown"
    res = System.run_sync([
      "bash",
      "-c",
      line
    ])
    if res["exit_code"] != 0
      return {"status": 500, "body": "Failed to spawn review agent — check server log"}
    end

    # HTMX requests get the panel fragment back in-place (no redirect),
    # so the spinner appears without leaving the task page. Direct POST
    # without the HX-Request header still falls back to a redirect so
    # the action stays usable from curl / non-htmx clients.
    if req["headers"]["hx-request"] == "true"
      _pkr = this._picker_locals_for(task)
      return {
        "status": 200,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": render_partial(
          "tasks/code_review",
          {
            "project": project,
            "task": task,
            "default_plan_model": _pkr["default_plan_model"],
            "claude_options": _pkr["claude_options"],
            "opencode_options": _pkr["opencode_options"],
            "reviews": CodeReview.for_task(project["name"], task.slug)
          }
        )
      }
    end
    redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
  end

  # Helper: package the locals the code-review partial needs (model
  # picker options + global default) so both `code_review` and `show`
  # can hand the partial the same shape.
  def _picker_locals_for(task)
    saved = (task.model ?? "").trim()
    picker = plan_model_picker_data(saved)
    {
      "claude_options": picker["claude_options"],
      "opencode_options": picker["opencode_options"],
      "default_plan_model": Plan.default_plan_model()
    }
  end

  def save(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    if task.status != "todo"
      return {
        "status": 422,
        "body": "Can only edit tasks in todo (current: " + task.status + ")"
      }
    end

    # Read via `req["all"]` (route + query + form + JSON merged) so the
    # same code path works for production htmx form posts and the test
    # client (which sends JSON).
    form = req["all"] ?? {}
    task.body_md = form["body_md"] ?? ""
    title = (form["title"] ?? "").trim()
    task.title = title if title != ""

    # Persist the model picker choice when the form carries one — lets the
    # user pre-save a model before clicking Queue. Skipped when absent so
    # callers that POST a partial form don't clobber an existing choice.
    raw_model = (form["plan_model"] ?? "").trim()
    task.model = _stitched_plan_model(form) if raw_model != ""
    task.save()
    if task._errors
      @title = task.slug
      @project = project
      @task = task
      @feature = this._feature_for_task(task)
      return render("tasks/show")
    end
    redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
  end

  def queue(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    # Pick-model-and-queue in one step: when the Queue form posts a
    # `plan_model` field, persist it before the limit check so the
    # effective-agent budget is computed against the chosen model.
    form = req["all"] ?? {}
    queue_model = (form["plan_model"] ?? "").trim()
    if queue_model != ""
      task.model = _stitched_plan_model(form)
      task.save()
      if task._errors
        return {"status": 422, "body": "Save failed"}
      end

    end
    denied = this._queue_limit_denial(task)
    return this._queue_limit_response(req, project, denied) if denied.present?
    changer = this._current_changer(req)
    this._move_response(req, fn(t) {
      t.change_author = changer
      t.queue!()
    })
  end

  def unqueue(req)
    changer = this._current_changer(req)
    this._move_response(req, fn(t) {
      t.change_author = changer
      t.unqueue!()
      Run.clear_run_state(t.project, t.slug)
    })
  end

  def archive(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    if task.status != "todo" && task.status != "done" && task.status != "failed"
      return {
        "status": 422,
        "body": "archive is only available for todo, done, or failed tasks " + "(current: " + task.status
        + ")"
      }
    end

    task.change_author = this._current_changer(req)
    task.status = "archived"
    task.save()
    if task._errors
      return {"status": 422, "body": "Save failed"}
    end

    redirect("/projects/" + project["name"] + "/tasks/" + task.slug)
  end

  def unarchive(req)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    if task.status != "archived"
      return {
        "status": 422,
        "body": "unarchive is only available for archived tasks (current: " + task.status + ")"
      }
    end

    task.change_author = this._current_changer(req)
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
  def _queue_limit_denial(task)
    agent = Task.effective_agent(task)
    daily_cap = Setting.get_or("limit_daily_" + agent, 0)
    weekly_cap = Setting.get_or("limit_weekly_" + agent, 0)
    if daily_cap > 0
      used_day = Task.usage_by_agent("day")[agent] ?? 0
      if used_day >= daily_cap
        return {
          "agent": agent,
          "window": "day",
          "used": used_day,
          "cap": daily_cap
        }
      end

    end
    if weekly_cap > 0
      used_week = Task.usage_by_agent("week")[agent] ?? 0
      if used_week >= weekly_cap
        return {
          "agent": agent,
          "window": "week",
          "used": used_week,
          "cap": weekly_cap
        }
      end

    end
    return nil
  end

  # Build the 422 response for a denied queue. HTMX requests get an
  # inline error fragment that renders inside the existing `#board`
  # target; plain form posts get a plain text 422 the browser shows
  # directly.
  def _queue_limit_response(req, project, denied)
    msg = "agent " + denied["agent"] + " is at its " + denied["window"] + " limit (" + str(denied["used"])
    + "/"
    + str(denied["cap"])
    + "). Adjust caps in /settings."
    if req["headers"]["hx-request"] == "true"
      columns = Task.board_for(project["name"])
      active = "todo"
      return {
        "status": 422,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": render_partial(
          "projects/board",
          {
            "project": project,
            "columns": columns,
            "indicators": indicators_for(project["name"], columns),
            "totals": totals_for(project["name"], columns),
            "agents": agents_for(columns),
            "statuses": Task.kanban_statuses(),
            "active_tab": active,
            "limit_error": msg
          }
        )
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
  def _current_changer(req)
    user = req["current_user"] rescue nil
    return user.email ?? "" if user.present?
    return session_get("user_email") ?? ""
  end

  # Shared dispatch for queue/unqueue. HTMX requests get the live board
  # fragment (so the kanban swaps in place); plain form posts get the full
  # redirect to the project page.
  def _move_response(req, action)
    project = Project.find_project(req["params"]["name"])
    if project.nil?
      return {"status": 404, "body": "Unknown project"}
    end

    task = Task.find_by_slug(project["name"], req["params"]["slug"])
    if task.nil?
      return {"status": 404, "body": "Task not found"}
    end

    action(task)
    if task._errors
      return {"status": 422, "body": "Save failed"}
    end

    if req["headers"]["hx-request"] == "true"
      columns = Task.board_for(project["name"])
      # After an action the task's new status is the most useful tab to
      # land on — the user sees the row appear in its new column.
      active = task.status
      active = "todo" if columns[active].nil?
      return {
        "status": 200,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": render_partial(
          "projects/board",
          {
            "project": project,
            "columns": columns,
            "indicators": indicators_for(project["name"], columns),
            "totals": totals_for(project["name"], columns),
            "agents": agents_for(columns),
            "statuses": Task.kanban_statuses(),
            "active_tab": active
          }
        )
      }
    end
    redirect("/projects/" + project["name"])
  end
end

# --- Shared top-level helpers -----------------------------------------
# These remain top-level fns so cross-controller and view callers
# (features_controller, settings_controller, runs_controller, debug_controller,
# views/features/_plan_model_select.html.slv) can reach them without going
# through an OOP method-resolve. Soli's WebSocket dispatcher also resolves
# action names from the global env — `code_review_stream` must live here.

# Pre-compute the locals the `features/plan_model_select` partial needs.
# Built purely from the DB allowlist — never shells out to opencode.
# View templates can't resolve model classes, so the partitioning into
# Claude vs opencode happens here and is threaded into render() as
# `claude_options` / `opencode_options`. The settings page is the only
# caller that needs the full unfiltered opencode universe; it calls
# `list_opencode_models()` directly to render the allowlist panel.
fn plan_model_picker_data(current)
  allow = Plan.allowed_model_ids()
  claude_all = Plan.claude_model_ids()
  labels = Plan.claude_model_labels()
  claude_set = {}
  for c in claude_all
    claude_set[c] = true
  end
  claude_ids = []
  opencode_ids = []
  codex_ids = []
  for id in allow
    if claude_set[id] == true
      claude_ids.push(id)
    elsif id.starts_with("codex/")
      codex_ids.push(id)
    else
      opencode_ids.push(id)
    end
  end
  claude_ids = claude_all if allow.length() == 0
  cur = (current ?? "").trim()
  if cur != ""
    seen = false
    for c in claude_ids
      seen = true if c == cur
    end
    for o in opencode_ids
      seen = true if o == cur
    end
    for cx in codex_ids
      seen = true if cx == cur
    end
    if !seen
      if claude_set[cur] == true
        claude_ids.push(cur)
      elsif cur.starts_with("codex/")
        codex_ids.push(cur)
      else
        opencode_ids.push(cur)
      end
    end
  end
  claude_opts = []
  for id in claude_ids
    claude_opts.push({"id": id, "label": labels[id] ?? id})
  end
  {
    "claude_options": claude_opts,
    "opencode_options": opencode_ids,
    "codex_options": codex_ids
  }
end

fn _models_skip_shellout()

  # Suite-wide kill-switch for `opencode models` / `codex models` shellouts
  # during tests. APP_ENV=test is set by `soli test` on every test-server
  # child regardless of which per-worker SOLIDB_DATABASE it's pointed at,
  # so this works for `--jobs 1` and `--jobs N` alike. Cuts settings spec
  # from 30s (84 tests × shellout latency) to under 1s.
  (getenv("APP_ENV") ?? "") == "test"
end

# Shell out to `opencode models`, return the (possibly empty) list of
# `provider/model` strings. Cached in the Setting table for 5 minutes so
# we don't pay the shell exec on every page load. The cache reflects
# whatever opencode currently has configured — providers come and go,
# but not faster than the TTL.
fn list_opencode_models
  return [] if _models_skip_shellout()
  cached = Setting.get_or("opencode_models_cache", nil)
  if cached.present?
    age = (cached["_cached_at"] ?? 0)
    return cached["models"] ?? [] if DateTime.now().to_unix() - age < 300
  end
  res = System.run_sync(["opencode", "models"]) rescue nil
  return [] if res.nil? || res["exit_code"] != 0
  lines = (res["stdout"] ?? "").split("\n")
  out = []
  for line in lines
    s = line.trim()
    out.push(s) if _looks_like_opencode_model(s)
  end
  Setting.set(
    "opencode_models_cache",
    {"_cached_at": DateTime.now().to_unix(), "models": out}
  )
  out
end

fn list_codex_models
  return [] if _models_skip_shellout()
  cached = Setting.get_or("codex_models_cache", nil)
  if cached.present?
    age = (cached["_cached_at"] ?? 0)
    return cached["models"] ?? [] if DateTime.now().to_unix() - age < 300
  end
  res = System.run_sync(["codex", "models"]) rescue nil
  return [] if res.nil? || res["exit_code"] != 0
  lines = (res["stdout"] ?? "").split("\n")
  out = []
  for line in lines
    s = line.trim()
    out.push("codex/" + s) if s.length() > 0
  end
  Setting.set(
    "codex_models_cache",
    {"_cached_at": DateTime.now().to_unix(), "models": out}
  )
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
  return false if s.length() == 0 || s.length() > 200
  slash = s.index_of("/")
  return false if slash <= 0 || slash == s.length() - 1
  provider = s.substring(0, slash)
  rest = s.substring(slash + 1, s.length)
  colon = rest.index_of(":")
  model = rest
  variant = ""
  if colon > 0
    model = rest.substring(0, colon)
    variant = rest.substring(colon + 1, rest.length)
  end
  return false if !_matches_charset(provider, "provider") || !_matches_charset(model, "model")
  return false if variant.length() > 0 && !_matches_charset(variant, "variant")
  return true
end

fn _matches_charset(s, kind)
  return false if s.length() == 0
  i = 0
  while i < s.length()
    c = s.substring(i, i + 1)
    ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "_"

    # Model segment also allows "." (e.g. "MiniMax-M2.5").
    ok = true if !ok && kind == "model" && c == "."

    # Variants are lowercase ascii only ("low", "medium", "high",
    # "minimal", "max"). Stricter than the model/provider charset on
    # purpose — keeps the surface small.
    ok = c >= "a" && c <= "z" if kind == "variant"
    return false if !ok
    i = i + 1
  end
  return true
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
  return nil if task.status != "inprogress" && task.status != "review" && task.status != "done"
  branch_name = Run.task_branch_name(task.slug)
  project_path = project["path"]
  exists_in_project = Run.task_branch_exists(project_path, task.slug)
  wt_path = Run.run_worktree_path(project["name"], task.slug)
  wt_exists = Run.run_worktree_exists(project["name"], task.slug)
  exists_in_worktree = wt_exists && Run.task_worktree_branch_exists(project["name"], task.slug)
  exists = exists_in_project || exists_in_worktree
  {
    "name": branch_name,
    "main": Run.project_main_branch(project_path),
    "exists": exists,
    "merged": Run.task_branch_merged(project_path, task.slug),
    "worktree_path": exists_in_worktree ? wt_path : nil,
    "is_local_branch": task.outcome == "local-branch",
    "has_github_remote": Run.project_has_remote(project_path)
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
  nonce = str(DateTime.now().to_unix() rescue 0)
  plan_id = "plan-" + nonce
  notes_path = "/tmp/plan-task-" + nonce + ".md"
  Run.plan_write_notes(notes_path, notes)
  project = ""
  if project_path.present? && project_path != ""
    segs = project_path.split("/")
    project = segs[segs.length() - 1] if segs.length() > 0
  end

  # stream_token gates the /ws/feature-generate-stream WS route to prevent
  # anonymous callers from reading a feature plan's transcript. The token is
  # random and per-plan; it is rendered into the show page (server-rendered,
  # auth-gated) and echoed back on every WS tick. plan-stream / run-stream
  # do not use this field (their HTTP counterparts are already public).
  token_nonce = str(DateTime.now().to_unix_millis() rescue 0) + "-" + str(Math.random() * 1000000 rescue 0)
  plan = Plan.create({
    "_key": plan_id,
    "project": project,
    "plan_id": plan_id,
    "status": "starting",
    "model": model,
    "prompt": notes,
    "project_path": project_path,
    "body": "",
    "log": "",
    "pending_question": nil,
    "zombie": false,
    "stream_token": token_nonce
  })
  line = "nohup ./bin/plan-run " + plan_id + " " + notes_path + " " + model + " " + project_path
  + " >/dev/null 2>&1 & disown"
  res = System.run_sync([
    "bash",
    "-c",
    line
  ])
  return nil if res["exit_code"] != 0
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
  v = (value ?? "").trim()
  claude_allowed = ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
  for a in claude_allowed
    return v if v == a
  end
  return v if _looks_like_opencode_model(v)
  "claude-sonnet-4-6"
end

# Stitch the form's plan_model with its plan_variant ("low" / "medium" /
# "high" / "minimal" / "max"). Variants only apply to opencode-shape
# models — claude SDK ids ignore the variant. Returns a value that is
# already validated by _allow_plan_model, so the result is safe to
# store and forward to bin/task-run.
fn _stitched_plan_model(form)
  base = ((form ?? {})["plan_model"] ?? "").trim()
  variant = ((form ?? {})["plan_variant"] ?? "").trim()
  is_opencode = base.index_of("/") > 0
  if is_opencode && variant != "" && variant != "default" && _matches_charset(variant, "variant")
    return _allow_plan_model(base + ":" + variant)
  end

  return _allow_plan_model(base)
end

# WebSocket handler for the code-review panel. The client opens a
# socket per running review and ticks until status is terminal; on
# `reload: true` it triggers a panel re-fetch so the spinner is
# replaced with the completed history entry. Mirrors the protocol used
# by runs#stream / tasks#plan_stream. Must remain a top-level fn — Soli's
# WS dispatcher resolves action strings through the global env, not the
# OOP controller registry.
fn code_review_stream(event)
  event_type = event["type"]
  return {} if event_type != "message"
  raw = (event["message"] ?? "").trim()
  parsed = JSON.parse(raw) rescue nil
  if parsed.nil?
    return {"send": JSON.stringify({
      "event": "error",
      "message": "bad message",
      "terminal": true
    })}
  end

  review_id = (parsed["review_id"] ?? "").trim()
  offset = parsed["offset"] ?? 0
  frame_kind = parsed["type"] == "subscribe" ? "connect" : "message"
  data = code_review_stream_payload(review_id, frame_kind, offset)
  return {"send": JSON.stringify(data)} if data["event"] == "error"
  {"send": JSON.stringify(data)}
end

# `read_plan_state(plan_id)` lives in `app/models/plan.sl` so the WS
# stream handlers and the spec suite can both call it without going
# through HTTP. This module reaches for it as a free-standing function
# (auto-loaded with the model file at server boot).
