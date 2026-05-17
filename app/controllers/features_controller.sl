# Features controller — CRUD for product-level feature briefs plus
# the generate-tasks pipeline that turns a feature brief into linked
# Task rows via the plan-run agent.

class FeaturesController < ApplicationController
  title:              Any
  feature:            Any
  tasks:              Any
  proposed_tasks:     Any
  comments:           Any
  attachments_meta:   Any
  active_plan:        Any
  latest_plan:        Any
  current_user:       Any
  projects:           Any
  project:            Any
  versions:           Any
  claude_options:     Any
  opencode_options:   Any
  default_plan_model: Any

  # Set the @claude_options / @opencode_options / @default_plan_model fields
  # for the plan-model picker partial used by show/new/edit forms.
  def _set_picker_fields(feature)
    current = (feature == nil ? "" : (feature.plan_model ?? ""))
    pmd = plan_model_picker_data(current)
    @claude_options     = pmd["claude_options"]
    @opencode_options   = pmd["opencode_options"]
    @default_plan_model = this._default_plan_model()
  end

  # GET /features/:id
  def show(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    # Finalize any plan that already finished but whose tasks never got
    # imported — happens when the user refreshed the page during the
    # polling window so generate_tasks_log never saw the done signal.
    this._finalize_done_plans(feature, req["current_user"])
    # Reconcile the feature's status from its tasks: catches the
    # no-commit / local-branch flows where `bin/task-run` writes
    # `status=done` straight to the DB and `mark_done` never fires.
    feature.recompute_status!()
    all_tasks = feature.tasks()
    proposed = []
    linked = []
    for t in all_tasks
      tstatus = t.status ?? ""
      if tstatus == "proposed"
        proposed.push(t)
      else
        linked.push(t)
      end
    end
    comment_list = feature.comments()
    @title            = feature.title
    @feature          = feature
    @tasks            = linked
    @proposed_tasks   = proposed
    @comments         = comment_list
    @attachments_meta = this._attachments_meta_for(comment_list)
    @active_plan      = this._active_plan_for(feature)
    @latest_plan      = this._latest_plan_for(feature)
    @current_user     = req["current_user"]
    this._set_picker_fields(feature)
    render("features/show")
  end

  # Bulk-load attachment metadata for every comment in `comments` into a
  # single `{ blob_id => { name, type, size, created_at } }` hash. One
  # AQL pass instead of one Blob lookup per attachment in the view.
  def _attachments_meta_for(comments)
    ids = []
    for c in comments
      bids = c.attachment_blob_ids ?? []
      for b in bids
        ids.push(b)
      end
    end
    if ids.length() == 0
      return {}
    end
    rows = @sdbql{
      FOR d IN comment_attachments
        FILTER d._key IN #{ids}
        RETURN { "_key": d._key, "name": d.name, "type": d.type, "size": d["size"] }
    } rescue []
    by_key = {}
    for r in rows
      by_key[r["_key"]] = r
    end
    by_key
  end

  # Walk plans associated with this feature and import tasks for any
  # that are done-but-unimported. _import_tasks_once is idempotent and
  # unconditionally stamps the plan once it has run, so there's no risk
  # of looping on a plan that produced zero tasks.
  def _finalize_done_plans(feature, current_user)
    all = Plan.all() rescue []
    prefix = "Feature brief: " + feature.title
    for p in all
      status = p.status ?? ""
      if status != "done"
        next
      end
      if p.tasks_imported == true
        next
      end
      fslug = p.feature_slug ?? ""
      pproj = p.project ?? ""
      prompt = p.prompt ?? ""
      matches = fslug == feature._key
      if not matches and pproj == feature.project and prompt.starts_with(prefix)
        matches = true
      end
      if matches
        this._import_tasks_once(feature, p.plan_id, p.body ?? "", current_user)
      end
    end
  end

  # GET /features/new
  def new(req)
    project_name = ((req["query"] ?? {})["project"] ?? "").trim()
    project = nil
    if project_name != ""
      project = Project.find_project(project_name) rescue nil
    end
    @title    = "New Feature"
    @feature  = nil
    @projects = Project.list_projects() rescue []
    @project  = project
    @versions = this._versions_for_form(project_name)
    this._set_picker_fields(nil)
    render("features/new")
  end

  # Versions for the feature form picker — empty list when project is unknown
  # (so the picker hides itself rather than showing every project's cycles).
  def _versions_for_form(project_name)
    if project_name == nil or project_name == ""
      return []
    end
    Version.for_project(project_name) rescue []
  end

  # POST /features
  def create(req)
    form = req["all"] ?? {}
    project = (form["project"] ?? "").trim()
    title = (form["title"] ?? "").trim()
    description = (form["description"] ?? "").trim()
    status = (form["status"] ?? "draft").trim()
    plan_model = this._persisted_plan_model(form)
    slug = title.slugify()
    if project == "" or title == ""
      return {"status": 422, "body": "Project and title are required"}
    end
    # Feature routes are auth-gated (see config/routes.sl), so
    # `current_user` is always populated. The `?? ""` guard is defensive
    # only — keeps the row creatable if the session ever expires between
    # the middleware check and this action.
    author = ""
    if req["current_user"] != nil
      author = req["current_user"].email ?? ""
    end
    version_id = (form["version_id"] ?? "").trim()
    feature = Feature.create({
      "_key":        Feature.key_for(project, slug),
      "project":     project,
      "slug":        slug,
      "title":       title,
      "description": description,
      "status":      status,
      "plan_model":  plan_model,
      "version_id":  version_id,
      "author":      author
    })
    if feature._errors
      @title    = "New Feature"
      @feature  = feature
      @projects = Project.list_projects() rescue []
      @versions = this._versions_for_form(project)
      this._set_picker_fields(feature)
        return render("features/new")
    end
    redirect("/features/" + feature._key)
  end

  # GET /features/:id/edit
  def edit(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    @title    = "Edit — " + feature.title
    @feature  = feature
    @projects = Project.list_projects() rescue []
    @versions = this._versions_for_form(feature.project)
    this._set_picker_fields(feature)
    render("features/edit")
  end

  # POST /features/:id/update — explicit POST alias for the
  # resources() PUT route, since Soli's router doesn't honor a
  # `?_method=put` override on form submissions.
  def update(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    form = req["all"] ?? {}
    title = ((form["title"] ?? feature.title) ?? "").trim()
    description = ((form["description"] ?? feature.description) ?? "").trim()
    status = ((form["status"] ?? feature.status) ?? "").trim()
    if title == ""
      return {"status": 422, "body": "Title is required"}
    end
    feature.title = title
    feature.description = description
    feature.status = status
    feature.plan_model = this._persisted_plan_model(form)
    if form["version_id"] != nil
      feature.version_id = (form["version_id"] ?? "").trim()
    end
    feature.save()
    if feature._errors
      @title    = "Edit — " + title
      @feature  = feature
      @projects = Project.list_projects() rescue []
      @versions = this._versions_for_form(feature.project)
      this._set_picker_fields(feature)
        return render("features/edit")
    end
    redirect("/features/" + feature._key)
  end

  # POST /features/:id/promote
  # Move a draft brief onto the betting table — flips status from
  # `draft` to `ready`. No-op if already `ready` (or further). Used by
  # the Shape tab's "Promote to bet" button. Optionally accepts
  # `version_id` so the user can promote-and-bet in one action.
  def promote(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    cur = feature.status ?? "draft"
    if cur == "draft"
      feature.status = "ready"
    end
    form = req["all"] ?? {}
    if form["version_id"] != nil
      feature.version_id = (form["version_id"] ?? "").trim()
    end
    feature.save()
    if feature._errors
      return {"status": 422, "body": "Could not promote: " + str(feature._errors)}
    end
    redirect("/projects/" + feature.project + "?tab=bet")
  end

  # POST /features/:id/assign-cycle
  # Inline cycle reassignment from the project hub's Features tab.
  # Empty version_id removes the assignment (back to Unscheduled).
  def assign_cycle(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    form = req["all"] ?? {}
    new_vid = (form["version_id"] ?? "").trim()
    if new_vid != ""
      version = Version.find_by("_key", new_vid) rescue nil
      if version == nil
        return {"status": 422, "body": "Unknown cycle"}
      end
      _vproj = version.project ?? ""
      if _vproj != feature.project
        return {"status": 422, "body": "Cycle belongs to a different project"}
      end
    end
    feature.version_id = new_vid
    feature.save()
    if feature._errors
      return {"status": 422, "body": "Could not assign cycle: " + str(feature._errors)}
    end
    redirect("/projects/" + feature.project + "?tab=features")
  end

  # POST /features/:id/publish
  # Bundle every `proposed` task linked to this feature into a single
  # new `todo` task and delete the originals. The combined body keeps
  # each sub-task as a `## Task N:` section, which the agent runs as one
  # unit — all sub-tasks share a single branch / worktree / PR.
  def publish(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    proposed = Task.where({ "feature_slug": feature._key, "status": "proposed" })
      .order("created_at", "asc")
      .all() rescue []
    if proposed.length() == 0
      return redirect("/features/" + feature._key)
    end
    combined_body = this._combine_task_bodies(feature, proposed)
    taken = this._existing_slugs_for_project(feature.project)
    slug  = this._unique_slug_local(taken, feature.title.slugify())
    author = ""
    if req["current_user"] != nil
      author = req["current_user"].email ?? ""
    end
    parent = Task.create({
      "_key":         Task.key_for(feature.project, slug),
      "project":      feature.project,
      "slug":         slug,
      "title":        feature.title,
      "body_md":      combined_body,
      "status":       "todo",
      "feature_slug": feature._key,
      "model":        feature.plan_model ?? "",
      "author":       author
    })
    if parent._errors
      return {"status": 422, "body": "Could not publish: " + str(parent._errors)}
    end
    for t in proposed
      t.delete()
    end
    if feature.status != "in-progress" and feature.status != "done"
      feature.status = "in-progress"
      feature.save()
    end
    redirect("/features/" + feature._key)
  end

  # Render the proposed task list as one markdown blob that the agent
  # can run end-to-end on a single branch. The feature description
  # leads, then each proposed task contributes a `## Task N: <title>`
  # section.
  def _combine_task_bodies(feature, tasks)
    parts = []
    desc = (feature.description ?? "").trim()
    if desc != ""
      parts.push("# " + feature.title)
      parts.push("")
      parts.push(desc)
      parts.push("")
      parts.push("---")
      parts.push("")
    end
    i = 1
    for t in tasks
      parts.push("## Task " + str(i) + ": " + (t.title ?? ""))
      parts.push("")
      parts.push((t.body_md ?? "").trim())
      parts.push("")
      i = i + 1
    end
    parts.join("\n")
  end

  # POST /features/:id/tasks/:slug/remove
  # Delete a single proposed task. Refuses non-proposed tasks so we can't
  # accidentally wipe a queued/running task from this surface.
  def remove_task(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    task = Task.find_by_slug(feature.project, req["params"]["slug"]) rescue nil
    if task == nil
      return {"status": 404, "body": "Task not found"}
    end
    tfs = task.feature_slug ?? ""
    if tfs != feature._key
      return {"status": 422, "body": "Task is not linked to this feature"}
    end
    if task.status != "proposed"
      return {"status": 422,
              "body": "Only proposed tasks can be removed from this surface " +
                      "(current: " + task.status + ")"}
    end
    task.delete()
    redirect("/features/" + feature._key)
  end

  # POST /features/:id/destroy
  def destroy(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    feature.delete()
    redirect("/features")
  end

  # POST /features/:id/generate_tasks
  # Spawns a plan-run agent with a multi-task prompt derived from the
  # feature's description. Returns an HTMX progress pane that polls
  # generate_tasks_log until tasks are created.
  def generate_tasks(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    description = (feature.description ?? "").trim()
    if description == ""
      return {"status": 422,
              "body": "Feature has no description — write one before generating tasks"}
    end
    this._spawn_generation(feature, "", req["all"] ?? {})
    plan = this._latest_plan_for(feature)
    if plan == nil
      return {
        "status": 500,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": "<div class=\"text-red-300 text-sm p-3\">failed to spawn plan-run</div>"
      }
    end
    {
      "status": 200,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": this._render_generate_card(feature, plan.plan_id,
                this._render_generate_log("", "spawning planner", false, feature),
                plan.stream_token ?? "")
    }
  end

  # POST /features/:id/regenerate_tasks
  # Wipe every existing proposed task linked to the feature, then run a
  # fresh plan using the original feature brief. Used by the "Discard &
  # regenerate" button on the interactive panel.
  def regenerate_tasks(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    this._wipe_proposed_tasks(feature)
    this._spawn_generation(feature, "", req["all"] ?? {})
    redirect("/features/" + feature._key)
  end

  # POST /features/:id/refine_tasks
  # Wipe proposed tasks and re-run the plan with the feature brief plus
  # free-text refinement context the user types in the panel.
  def refine_tasks(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    form = req["all"] ?? {}
    refinement = (form["refinement"] ?? "").trim()
    if refinement == ""
      return {"status": 422, "body": "Refinement text is required"}
    end
    this._wipe_proposed_tasks(feature)
    this._spawn_generation(feature, refinement, form)
    redirect("/features/" + feature._key)
  end

  # POST /features/:id/cancel_plan
  # Mark the most recent plan as user-cancelled so the UI stops polling
  # and `_finalize_done_plans` ignores it. The background plan-run
  # process keeps running on disk — its output won't be imported because
  # `tasks_imported` is stamped here. (We don't signal-kill the process
  # from inside the app; the user can do that out-of-band if needed.)
  def cancel_plan(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    plan = this._latest_plan_for(feature)
    if plan != nil
      status = plan.status ?? ""
      if status != "done" and not status.starts_with("failed:")
        plan.status = "failed:cancelled"
      end
      plan.tasks_imported = true
      plan.save()
    end
    redirect("/features/" + feature._key)
  end

  # Shared spawn helper: assembles the prompt (brief + optional
  # refinement) and starts a plan-agent run tagged with this feature.
  # `form` carries the optional per-run model override; falls back to
  # `feature.plan_model` then the global `plan_model` setting.
  def _spawn_generation(feature, refinement, form)
    description = (feature.description ?? "").trim()
    prompt = "Feature brief: " + feature.title + "\n\n" + description
    if refinement != ""
      prompt = prompt + "\n\n---\n\nRefinement from user (use this to shape " +
        "or focus the task list):\n\n" + refinement
    end
    prompt = prompt + "\n\n---\n\n" +
      "Based on the feature brief above, generate a list of " +
      "implementation tasks. Each task should be a self-contained " +
      "unit of work. Output the tasks in this format:\n\n" +
      "## Task 1: <title>\n\n" +
      "<markdown description>\n\n" +
      "## Task 2: <title>\n\n" +
      "<markdown description>\n\n" +
      "Keep each task focused and actionable. Produce 3-7 tasks."
    model = Plan.resolve_plan_model(feature, form)
    project_path = this._feature_project_path(feature)
    plan_id = spawn_plan_agent(prompt, model, project_path)
    if plan_id == nil
      return nil
    end
    plan = Plan.find_by_plan_id(plan_id)
    if plan != nil
      plan.feature_slug   = feature._key
      plan.tasks_imported = false
      plan.save()
    end
    plan_id
  end

  # GET /features/:id/generate_tasks_log/:plan_id
  # HTMX poll endpoint for the generate-tasks plan-run. When the plan
  # completes, parses the output into individual Task rows linked to
  # the feature, then redirects to the feature show page.
  def generate_tasks_log(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    plan_id = req["params"]["plan_id"]
    state = read_plan_state(plan_id)
    if state["status"] == "done"
      this._import_tasks_once(feature, plan_id, state["body"], req["current_user"])
      return {
        "status": 200,
        "headers": {
          "Content-Type": "text/html; charset=utf-8",
          "HX-Redirect": "/features/" + feature._key
        },
        "body": ""
      }
    end
    failed = state["status"].starts_with("failed:")
    pq = state["pending_question"]
    has_question = pq != nil and pq["input"] != nil and pq["input"]["questions"] != nil
    if has_question
      return {
        "status": 200,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": this._render_generate_question(feature, plan_id, pq, state["log"] ?? "", state["status"])
      }
    end
    {
      "status": 200,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": this._render_generate_progress(feature, plan_id,
                this._render_generate_log(state["log"] ?? "", state["status"], failed, feature),
                state["log"] ?? "",
                state["stream_token"] ?? "")
    }
  end

  # POST /features/:id/plan-answer/:plan_id
  # Mirrors tasks#plan_answer: writes the user's chosen option as the
  # pending_answer so the plan-run agent's pollAnswer() loop picks it up.
  # When the plan finishes between the last poll and the answer response,
  # imports tasks and redirects the feature page.
  def plan_answer(req)
    feature = this._find_feature(req)
    if feature == nil
      return {"status": 404, "body": "Feature not found"}
    end
    plan_id = req["params"]["plan_id"]
    body_params = req["all"] ?? {}
    qid = (body_params["qid"] ?? "").trim()
    value = (body_params["value"] ?? "").trim()
    if qid == "" or value == ""
      return {"status": 422, "body": "qid and value required"}
    end
    plan = Plan.find_by_plan_id(plan_id)
    if plan != nil
      plan.write_pending_answer(qid, value)
    end
    state = read_plan_state(plan_id)
    if state["status"] == "done"
      this._import_tasks_once(feature, plan_id, state["body"], req["current_user"])
      return {
        "status": 200,
        "headers": {
          "Content-Type": "text/html; charset=utf-8",
          "HX-Redirect": "/features/" + feature._key
        },
        "body": ""
      }
    end
    failed = state["status"].starts_with("failed:")
    {
      "status": 200,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": this._render_generate_progress(feature, plan_id,
                this._render_generate_log(state["log"] ?? "", state["status"], failed, feature),
                state["log"] ?? "",
                state["stream_token"] ?? "")
    }
  end

  # ── helpers ──

  def _find_feature(req)
    id = req["params"]["id"]
    Feature.find_by("_key", id)
  end

  def _feature_project_path(feature)
    proj = Project.find_project(feature.project) rescue nil
    if proj != nil
      return proj["path"]
    end
    root = Project.workspace_root()
    return root + "/" + feature.project
  end

  def _default_plan_model()
    Plan.default_plan_model()
  end

  # Used by create/update to decide whether to store a non-empty value
  # on the Feature row. Returns "" when the form didn't include a model
  # (so the row falls back to the global default) — `Plan.resolve_plan_model`
  # treats both nil and "" as "not set".
  def _persisted_plan_model(form)
    raw = ((form ?? {})["plan_model"] ?? "").trim()
    if raw == ""
      return ""
    end
    Plan.resolve_plan_model(nil, form)
  end

  # Find the plan associated with this feature that still needs the
  # progress block re-attached. Two paths:
  #  1) Plans tagged with `feature_slug` (the normal case from now on).
  #  2) Fallback: plans whose prompt starts with `Feature brief: <title>`
  #     in the same project — catches in-flight plans created before
  #     the feature_slug tag landed.
  # Returns nil when nothing needs re-attaching.
  def _active_plan_for(feature)
    all = Plan.all() rescue []
    sorted = all.sort_by(fn(p) p.plan_id ?? "").reverse()
    for p in sorted
      fslug = p.feature_slug ?? ""
      if fslug == feature._key and this._plan_needs_attention(p)
        return p
      end
    end
    prefix = "Feature brief: " + feature.title
    for p in sorted
      pproj = p.project ?? ""
      if pproj != feature.project
        next
      end
      prompt = p.prompt ?? ""
      if prompt.starts_with(prefix) and this._plan_needs_attention(p)
        return p
      end
    end
    nil
  end

  # Most recent plan tied to this feature (any status) — used by the
  # interactive panel on the feature page so we can show the log /
  # refine / regenerate / cancel controls regardless of whether the
  # plan is still running.
  def _latest_plan_for(feature)
    all = Plan.all() rescue []
    sorted = all.sort_by(fn(p) p.plan_id ?? "").reverse()
    for p in sorted
      fslug = p.feature_slug ?? ""
      if fslug == feature._key
        return p
      end
    end
    prefix = "Feature brief: " + feature.title
    for p in sorted
      pproj = p.project ?? ""
      if pproj == feature.project
        prompt = p.prompt ?? ""
        if prompt.starts_with(prefix)
          return p
        end
      end
    end
    nil
  end

  # Hard-delete every proposed task linked to this feature. Used before
  # refine / regenerate so the new run replaces the old proposals.
  def _wipe_proposed_tasks(feature)
    rows = Task.where({ "feature_slug": feature._key, "status": "proposed" })
      .all() rescue []
    for t in rows
      t.delete()
    end
    rows.length()
  end

  # A plan needs the progress block re-rendered when it is still running
  # OR it has finished but its tasks haven't been imported into the feature
  # yet (the polling endpoint that does the import never fired because the
  # page was refreshed away).
  def _plan_needs_attention(plan)
    # Use `effective_status` (not the raw field) so a plan that died
    # without writing its final status — e.g. SIGKILLed mid-run, leaving
    # status="starting" pid=null — is treated as terminal via the
    # `failed:zombie` synthesis path. Without this, the show page picks
    # the zombie row as active_plan, the WS reports terminal=true, the
    # client reloads, and the next render picks the same zombie → an
    # infinite reload loop.
    status = plan.effective_status ?? ""
    if status.starts_with("failed:")
      return false
    end
    if status == "done"
      return plan.tasks_imported != true
    end
    true
  end

  # Idempotent: parse the plan body once, create the Task rows, and tag
  # the plan as imported. We mark `tasks_imported=true` even when zero
  # tasks were created — the alternative caused an infinite redirect
  # loop, because the polling endpoint redirects on done and the next
  # page visit kept finding the plan "still needs attention".
  # The actual count is stored in `imported_task_count` for the UI to
  # surface a "0 tasks created" notice.
  def _import_tasks_once(feature, plan_id, body, current_user)
    plan = Plan.find_by_plan_id(plan_id)
    if plan != nil and plan.tasks_imported == true
      return 0
    end
    count = this._create_tasks_from_body(feature, body, current_user)
    if plan != nil
      plan.tasks_imported      = true
      plan.imported_task_count = count
      plan.feature_slug        = feature._key
      plan.save()
    end
    count
  end

  # Parse a multi-task plan body and create linked Task rows. Expects
  # `## Task N: <title>` sections. Returns the count of created tasks.
  #
  # Batch-loads existing slugs for the project up-front so each section's
  # uniqueness check is a hashmap lookup, not a per-section
  # `Task.find_by_slug` (Soli's N+1 lint panics when the diagnostic
  # message it tries to display contains the multiplier char it can't
  # substring cleanly).
  def _create_tasks_from_body(feature, body, current_user)
    author = ""
    if current_user != nil
      author = current_user.email ?? ""
    end
    sections = _parse_task_sections(body)
    taken = this._existing_slugs_for_project(feature.project)
    count = 0
    for section in sections
      slug = this._unique_slug_local(taken, section["title"].slugify())
      taken[slug] = true
      task = Task.create({
        "_key":         Task.key_for(feature.project, slug),
        "project":      feature.project,
        "slug":         slug,
        "title":        section["title"],
        "body_md":      section["body"],
        "status":       "proposed",
        "feature_slug": feature._key,
        "author":       author
      })
      if not task._errors
        count = count + 1
      end
    end
    if count > 0 and feature.status == "draft"
      feature.status = "ready"
      feature.save()
    end
    count
  end

  # `{ slug: true, ... }` for every existing task in `project` — one
  # `Task.where` call instead of N `Task.find_by_slug` lookups.
  def _existing_slugs_for_project(project)
    by_slug = {}
    rows = Task.where({ "project": project }).all() rescue []
    for t in rows
      by_slug[t.slug ?? ""] = true
    end
    by_slug
  end

  # Local-only unique slug picker — no DB round-trips. `taken` is a hash
  # of slugs already in use (returned by _existing_slugs_for_project).
  def _unique_slug_local(taken, base)
    b = base
    if b == ""
      b = "task"
    end
    candidate = b
    n = 2
    while taken[candidate] == true and n <= 100
      candidate = b + "-" + str(n)
      n = n + 1
    end
    candidate
  end

  # Pull a sensible task title out of a single-blob plan body — the first
  # top-level heading if present, otherwise the first non-blank line
  # (truncated), otherwise a fixed fallback.
  def _first_heading_or_default(raw)
    for line in raw.split("\n")
      l = line.trim()
      if l.starts_with("# ")
        return l.substring(2, l.length).trim()
      end
      if l.starts_with("## ")
        return l.substring(3, l.length).trim()
      end
    end
    for line in raw.split("\n")
      l = line.trim()
      if l != ""
        if l.length() > 60
          return l.substring(0, 60).trim() + "..."
        end
        return l
      end
    end
    "Generated task"
  end

  # WebSocket handler for the generate-tasks plan-run transcript.
  #
  # Mirrors `runs#stream` / `tasks#plan_stream`: the client opens the
  # socket, sends `tick` frames with its byte cursor, the server replies
  # with `delta` frames carrying any new bytes plus a re-rendered status
  # pill. Questions are handled by the htmx poll path
  # (`generate_tasks_log`) so `question_html` is omitted. On a done
  # status we set `reload: true` so the client navigates to the feature
  # page, where `_import_tasks_once` will have synced the proposed tasks.
  #
  # Access is gated by the `stream_token` nonce minted in `spawn_plan_agent`
  # and rendered into the auth-gated show page. The client echoes it back
  # on every tick; we reject the stream if it doesn't match.
  #
  # The actual handler is the top-level `generate_stream(event)` fn below.
  # Soli's WS dispatcher resolves action names through the global env, not
  # the OOP controller registry, so WS handlers must remain top-level fns
  # even when the surrounding controller is class-based.

  # Outer card (initial POST response): full Plan Agent card with the
  # running badge and the polling div seeded inside. Used as the body of
  # HTML-escape — mirrors `application_helper.h` so class methods that
  # can't reach view helpers from instance scope still escape user-
  # supplied content (status tokens, question text) when building HTML
  # snippets inline.
  def _esc(text)
    (text ?? "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
  end

  # the initial generate_tasks response so the click visibly replaces
  # the Generate Tasks button with a running progress panel.
  def _render_generate_card(feature, plan_id, inner, stream_token)
    "<div class=\"mb-6 rounded-2xl glass-card p-6 relative overflow-hidden animate-fade-in card-glow\">" +
    "<div class=\"absolute -top-12 -right-12 w-48 h-48 rounded-full bg-fuchsia-500/15 " +
    "blur-3xl pointer-events-none\"></div>" +
    "<div class=\"relative\">" +
    "<div class=\"flex items-center gap-2 mb-2\">" +
    "<span class=\"relative flex h-2.5 w-2.5\">" +
    "<span class=\"animate-ping absolute inline-flex h-full w-full rounded-full bg-fuchsia-400 opacity-75\"></span>" +
    "<span class=\"relative inline-flex rounded-full h-2.5 w-2.5 bg-fuchsia-400\"></span>" +
    "</span>" +
    "<h2 class=\"text-sm font-semibold uppercase tracking-wider text-fuchsia-300\">Plan Agent &mdash; running</h2>" +
    "<span class=\"text-xs text-slate-500 font-mono\">" + this._esc(plan_id) + "</span>" +
    "</div>" +
    "<p class=\"text-xs text-slate-500 mb-3\">Streaming live &mdash; tasks will appear " +
    "here as the planner produces them.</p>" +
    this._render_generate_progress(feature, plan_id, inner, "", stream_token) +
    "</div></div>"
  end

  def _render_generate_progress(feature, plan_id, inner, initial_log, stream_token)
    # Streaming runs over a WebSocket: the data-stream-* attributes wire
    # the panel up to the global `run-stream.js` client, replacing the
    # `every 2s` htmx poller. The same panel is re-rendered server-side
    # after each plan-answer so a fresh socket opens on the new DOM root.
    # The route URL is static (Soli 1.0.3's `router_websocket` doesn't
    # extract `:id`-style path params); the client echoes the identifiers
    # on every tick from the data-stream-* attrs.
    # `stream_token` gates the WS route so anonymous callers cannot subscribe.
    log_len = (initial_log ?? "").length()
    "<div id=\"generate-progress\"" +
    " data-stream-url=\"/ws/feature-generate-stream\"" +
    " data-stream-feature-id=\"" + feature._key + "\"" +
    " data-stream-plan-id=\"" + plan_id + "\"" +
    " data-stream-token=\"" + (stream_token ?? "") + "\"" +
    " data-stream-log=\"#generate-progress-log\"" +
    " data-stream-status=\"#generate-progress-status\"" +
    " data-stream-offset=\"" + str(log_len) + "\"" +
    " data-stream-tick-ms=\"300\">" +
    inner + "</div>"
  end

  def _render_generate_log(log, status, failed, feature)
    # Render the log body via the shared partial so SSR mirrors the
    # <pre>+<span> shape `appendLogChunk` (public/run-stream.js) expects.
    # Without it, the first WS delta wipes the initial log content.
    body = render_partial("features/generate_log_pre", { "log": log ?? "" })
    html = "<div id=\"generate-progress-log\" " +
      "class=\"text-sm font-mono text-slate-300 whitespace-pre-wrap " +
      "max-h-64 overflow-y-auto rounded-lg bg-slate-900/60 border " +
      "border-white/5 p-3\">" +
      body + "</div>"
    safe_status = this._esc(status)
    if failed
      html = html + "<div id=\"generate-progress-status\" class=\"text-red-400 text-sm mt-2\">" +
        "Plan failed: " + safe_status + ". " +
        "<a href=\"/features/" + feature._key + "\" " +
        "class=\"text-indigo-400 underline\">Back to feature</a></div>"
    else
      html = html + "<div id=\"generate-progress-status\" class=\"text-indigo-300 text-sm animate-pulse mt-2\">" +
        safe_status + "&hellip;</div>"
    end
    html
  end

  def _render_generate_question(feature, plan_id, pq, log, status)
    q = pq["input"]["questions"][0]
    multi = q["multiSelect"] == true
    html = "<div id=\"generate-progress\">"
    html = html + "<div class=\"mb-4 rounded-xl bg-amber-400/10 border border-amber-400/30 p-4\">"
    html = html + "<div class=\"text-xs text-amber-300/80 font-mono mb-1\">" +
      "human-in-the-loop · " + this._esc(pq["tool"] ?? "") + "</div>"
    html = html + "<div class=\"text-sm text-amber-100 mb-3\">" + this._esc(q["question"]) + "</div>"
    if multi
      html = html + "<form"
      html = html + " hx-post=\"/features/" + feature._key + "/plan-answer/" + plan_id + "\""
      html = html + " hx-target=\"#generate-progress\""
      html = html + " hx-swap=\"outerHTML\">"
      html = html + "<input type=\"hidden\" name=\"qid\" value=\"" + this._esc(pq["id"]) + "\">"
      for opt in q["options"]
        html = html + "<label class=\"block w-full text-left mb-1 px-3 py-2 rounded " +
          "bg-amber-400/5 hover:bg-amber-400/15 text-sm text-amber-100 " +
          "transition-colors cursor-pointer\">"
        html = html + "<input type=\"checkbox\" name=\"value\" value=\"" +
          this._esc(opt["label"]) + "\" class=\"mr-2\">"
        html = html + "<span class=\"font-medium\">" + this._esc(opt["label"]) + "</span>"
        if opt["description"] != nil and opt["description"] != ""
          html = html + "<span class=\"text-amber-300/60 text-xs ml-2\">— " +
            this._esc(opt["description"]) + "</span>"
        end
        html = html + "</label>"
      end
      html = html + "<button type=\"submit\" " +
          "class=\"block w-full mt-2 rounded bg-amber-500/20 hover:bg-amber-400/20 " +
          "text-sm text-amber-100 px-3 py-2 transition-colors font-medium\">"
      html = html + "Submit selection</button>"
      html = html + "</form>"
    else
      for opt in q["options"]
        vals = JSON.stringify({"qid": pq["id"], "value": opt["label"]})
        html = html + "<button type=\"button\""
        html = html + " hx-post=\"/features/" + feature._key + "/plan-answer/" + plan_id + "\""
        html = html + " hx-vals=\"" + this._esc(vals) + "\""
        html = html + " hx-target=\"#generate-progress\""
        html = html + " hx-swap=\"outerHTML\""
        html = html + " class=\"block w-full text-left mb-1 px-3 py-2 rounded " +
        "bg-amber-400/5 hover:bg-amber-400/15 text-sm text-amber-100 " +
        "transition-colors\">"
        html = html + "<span class=\"font-medium\">" + this._esc(opt["label"]) + "</span>"
        if opt["description"] != nil and opt["description"] != ""
          html = html + "<span class=\"text-amber-300/60 text-xs ml-2\">— " +
            this._esc(opt["description"]) + "</span>"
        end
        html = html + "</button>"
      end
    end
    html = html + "</div>"
    html = html + "<div id=\"generate-progress-log\" " +
      "class=\"text-sm font-mono text-slate-300 whitespace-pre-wrap " +
      "max-h-64 overflow-y-auto rounded-lg bg-slate-900/60 border " +
      "border-white/5 p-3\">" + this._esc(log) + "</div>"
    html = html + "<div class=\"text-indigo-300 text-sm animate-pulse mt-2\">" + this._esc(status) + "&hellip;</div>"
    html = html + "</div>"
    html
  end
end

# ── WebSocket handler — must be a top-level fn (see note above) ────────

fn generate_stream(event)
  event_type = event["type"]
  if event_type != "message"
    return {}
  end
  raw = (event["message"] ?? "").trim()
  parsed = JSON.parse(raw) rescue nil
  if parsed == nil
    return { "send": JSON.stringify({ "event": "error", "message": "bad message", "terminal": true }) }
  end
  feature_key = (parsed["feature_id"] ?? "").trim()
  # Use find_by to look up by _key — `Model.find` raises a framework 404
  # on miss, and the WS handler can't surface that the way a controller
  # action can. The sibling tasks/runs stream handlers use the same
  # find_by-style lookup for the same reason.
  feature = Feature.find_by("_key", feature_key) rescue nil
  if feature == nil
    return { "send": JSON.stringify({ "event": "error", "message": "unknown feature", "terminal": true }) }
  end
  plan_id = (parsed["plan_id"] ?? "").trim()
  offset = parsed["offset"] ?? 0
  frame_kind = parsed["type"] == "subscribe" ? "connect" : "message"
  # Validate stream_token so anonymous callers cannot subscribe.
  client_token = (parsed["stream_token"] ?? "").trim()
  state = read_plan_state(plan_id)
  if state["status"] == "unknown"
    return { "send": JSON.stringify({ "event": "error", "message": "unknown plan", "terminal": true }) }
  end
  if client_token != state["stream_token"]
    return { "send": JSON.stringify({ "event": "error", "message": "access denied", "terminal": true }) }
  end
  data = plan_stream_payload(plan_id, frame_kind, offset)
  if data["event"] == "error"
    return { "send": JSON.stringify(data) }
  end
  data["reload"] = data["terminal"]
  data["status_html"] = render_partial("tasks/plan_status", {
    "plan_id":          plan_id,
    "status":           data["status"],
    "pending_question": data["pending_question"]
  })
  # Questions are handled by the htmx poll endpoint; omit from the WS
  # delta so the client never enters `suppressed` mode.
  data["pending_question"] = nil
  { "send": JSON.stringify(data) }
end

# ── Shared top-level helper (debug_controller calls this bare) ─────────

# Split a plan body on `## Task` headings. Returns [{ title, body }].
# Fallback: if no `## Task` headings are present, the body is treated as
# a single self-contained task spec — the planner often emits one
# detailed brief instead of N labelled sections, and we'd rather create
# one task than zero.
fn _parse_task_sections(body)
  raw = (body ?? "").trim()
  if raw == ""
    return []
  end
  out = []
  if raw.contains("## Task")
    parts = raw.split("## Task")
    i = 0
    for part in parts
      if i == 0
        i = i + 1
      else
        first_newline = part.index_of("\n")
        heading_line = part
        if first_newline > 0
          heading_line = part.substring(0, first_newline)
        end
        colon = heading_line.index_of(":")
        title = heading_line
        if colon > 0
          title = heading_line.substring(colon + 1, heading_line.length)
        end
        title = title.trim()
        body_text = ""
        if first_newline > 0
          body_text = part.substring(first_newline + 1, part.length).trim()
        end
        if title != "" and title != "<title>"
          out.push({ "title": title, "body": body_text })
        end
        i = i + 1
      end
    end
  end
  if out.length() == 0
    out.push({ "title": _features_first_heading_or_default(raw), "body": raw })
  end
  out
end

# Top-level helper for _parse_task_sections's fallback path (which has no
# access to the FeaturesController instance method of the same name).
fn _features_first_heading_or_default(raw)
  for line in raw.split("\n")
    l = line.trim()
    if l.starts_with("# ")
      return l.substring(2, l.length).trim()
    end
    if l.starts_with("## ")
      return l.substring(3, l.length).trim()
    end
  end
  for line in raw.split("\n")
    l = line.trim()
    if l != ""
      if l.length() > 60
        return l.substring(0, 60).trim() + "..."
      end
      return l
    end
  end
  "Generated task"
end
