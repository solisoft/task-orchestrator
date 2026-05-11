# Features controller — CRUD for product-level feature briefs plus
# the generate-tasks pipeline that turns a feature brief into linked
# Task rows via the plan-run agent.

# GET /features
fn index(req)
  let project_filter = (req["query"]["project"] ?? "").trim()
  let features = []
  if project_filter != ""
    features = Feature.for_project(project_filter)
  else
    let projs = list_projects() rescue []
    for proj in projs
      for f in Feature.for_project(proj["name"])
        features.push(f)
      end
    end
  end
  render("features/index", {
    "title": "Features",
    "features": features,
    "projects": list_projects() rescue [],
    "project_filter": project_filter == "" ? nil : project_filter
  })
end

# GET /features/:id
fn show(req)
  let feature = _find_feature(req)
  if feature == nil
    return {"status": 404, "body": "Feature not found"}
  end
  render("features/show", {
    "title":    feature.title,
    "feature":  feature,
    "tasks":    feature.tasks(),
    "comments": feature.comments(),
    "current_user": req["current_user"]
  })
end

# GET /features/new
fn new(req)
  let project_name = (req["query"]["project"] ?? "").trim()
  let project = nil
  if project_name != ""
    project = find_project(project_name) rescue nil
  end
  render("features/new", {
    "title": "New Feature",
    "feature": nil,
    "projects": list_projects() rescue [],
    "project": project
  })
end

# POST /features
fn create(req)
  let form = req["all"] ?? {}
  let project = (form["project"] ?? "").trim()
  let title = (form["title"] ?? "").trim()
  let description = (form["description"] ?? "").trim()
  let status = (form["status"] ?? "draft").trim()
  let slug = title.slugify()
  if project == "" or title == ""
    return {"status": 422, "body": "Project and title are required"}
  end
  let feature = Feature.create({
    "_key":        Feature.key_for(project, slug),
    "project":     project,
    "slug":        slug,
    "title":       title,
    "description": description,
    "status":      status
  })
  if feature._errors
    return render("features/new", {
      "title": "New Feature",
      "feature": feature,
      "projects": list_projects() rescue []
    })
  end
  redirect("/features/" + feature._key)
end

# GET /features/:id/edit
fn edit(req)
  let feature = _find_feature(req)
  if feature == nil
    return {"status": 404, "body": "Feature not found"}
  end
  render("features/edit", {
    "title": "Edit — " + feature.title,
    "feature": feature,
    "projects": list_projects() rescue []
  })
end

# POST /features/:id (update via method override)
fn update(req)
  let feature = _find_feature(req)
  if feature == nil
    return {"status": 404, "body": "Feature not found"}
  end
  let form = req["all"] ?? {}
  let title = (form["title"] ?? feature.title).trim()
  let description = (form["description"] ?? feature.description).trim()
  let status = (form["status"] ?? feature.status).trim()
  if title == ""
    return {"status": 422, "body": "Title is required"}
  end
  feature.title = title
  feature.description = description
  feature.status = status
  feature.save()
  if feature._errors
    return render("features/edit", {
      "title": "Edit — " + title,
      "feature": feature,
      "projects": list_projects() rescue []
    })
  end
  redirect("/features/" + feature._key)
end

# POST /features/:id/destroy
fn destroy(req)
  let feature = _find_feature(req)
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
fn generate_tasks(req)
  let feature = _find_feature(req)
  if feature == nil
    return {"status": 404, "body": "Feature not found"}
  end
  let description = (feature.description ?? "").trim()
  if description == ""
    return {"status": 422,
            "body": "Feature has no description — write one before generating tasks"}
  end
  let model = _default_plan_model()
  let prompt = "Feature brief: " + feature.title + "\n\n"
             + description + "\n\n"
             + "---\n\n"
             + "Based on the feature brief above, generate a list of "
             + "implementation tasks. Each task should be a self-contained "
             + "unit of work. Output the tasks in this format:\n\n"
             + "## Task 1: <title>\n\n"
             + "<markdown description>\n\n"
             + "## Task 2: <title>\n\n"
             + "<markdown description>\n\n"
             + "Keep each task focused and actionable. Produce 3-7 tasks."
  let project_path = _feature_project_path(feature)
  let plan_id = spawn_plan_agent(prompt, model, project_path)
  if plan_id == nil
    return {
      "status": 500,
      "headers": {"Content-Type": "text/html; charset=utf-8"},
      "body": "<div class=\"text-red-300 text-sm p-3\">failed to spawn plan-run</div>"
    }
  end
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": _render_generate_progress(feature, plan_id,
              "Generating tasks from feature brief...")
  }
end

# GET /features/:id/generate_tasks_log/:plan_id
# HTMX poll endpoint for the generate-tasks plan-run. When the plan
# completes, parses the output into individual Task rows linked to
# the feature, then redirects to the feature show page.
fn generate_tasks_log(req)
  let feature = _find_feature(req)
  if feature == nil
    return {"status": 404, "body": "Feature not found"}
  end
  let plan_id = req["params"]["plan_id"]
  let state = read_plan_state(plan_id)
  if state["status"] == "done"
    _create_tasks_from_body(feature, state["body"], req["current_user"])
    return {
      "status": 200,
      "headers": {
        "Content-Type": "text/html; charset=utf-8",
        "HX-Redirect": "/features/" + feature._key
      },
      "body": ""
    }
  end
  let failed = state["status"].starts_with("failed:")
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": _render_generate_progress(feature, plan_id,
              _render_generate_log(state["log"] ?? "", state["status"], failed, feature))
  }
end

# ── helpers ──

fn _find_feature(req)
  let id = req["params"]["id"]
  Feature.find_by("_key", id)
end

fn _feature_project_path(feature)
  let proj = find_project(feature.project) rescue nil
  if proj != nil
    return proj["path"]
  end
  let root = workspace_root()
  return root + "/" + feature.project
end

fn _default_plan_model()
  Setting.get_or("agent_type", "claude-sonnet-4-6")
end

# Parse a multi-task plan body and create linked Task rows. Expects
# `## Task N: <title>` sections. Returns the count of created tasks.
fn _create_tasks_from_body(feature, body, current_user)
  let author = ""
  if current_user != nil
    author = current_user.email ?? ""
  end
  let sections = _parse_task_sections(body)
  let count = 0
  for section in sections
    let slug = unique_slug_for(feature.project, section["title"].slugify())
    let task = Task.create({
      "_key":         Task.key_for(feature.project, slug),
      "project":      feature.project,
      "slug":         slug,
      "title":        section["title"],
      "body_md":      section["body"],
      "status":       "todo",
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

# Split a plan body on `## Task` headings. Returns [{ title, body }].
fn _parse_task_sections(body)
  let out = []
  let raw = body ?? ""
  let parts = raw.split("## Task")
  let i = 0
  for part in parts
    if i == 0
      i = i + 1
    else
      let first_newline = part.index_of("\n")
      let heading_line = part
      if first_newline > 0
        heading_line = part.substring(0, first_newline)
      end
      let colon = heading_line.index_of(":")
      let title = heading_line
      if colon > 0
        title = heading_line.substring(colon + 1, heading_line.length)
      end
      title = title.trim()
      let body_text = ""
      if first_newline > 0
        body_text = part.substring(first_newline + 1, part.length).trim()
      end
      if title != ""
        out.push({ "title": title, "body": body_text })
      end
      i = i + 1
    end
  end
  out
end

fn _render_generate_progress(feature, plan_id, inner)
  "<div id=\"generate-progress\" hx-get=\"" +
  "/features/" + feature._key + "/generate_tasks_log/" + plan_id +
  "\" hx-trigger=\"every 2s\" hx-swap=\"outerHTML\">" +
  inner + "</div>"
end

fn _render_generate_log(log, status, failed, feature)
  let html = "<div class=\"text-sm font-mono text-slate-300 whitespace-pre-wrap max-h-64 overflow-y-auto mb-3\">" +
             h(log) + "</div>"
  if failed
    html = html + "<div class=\"text-red-400 text-sm\">" +
           "Plan failed: " + h(status) + ". " +
           "<a href=\"/features/" + feature._key + "\" " +
           "class=\"text-indigo-400 underline\">Back to feature</a></div>"
  else
    html = html + "<div class=\"text-indigo-300 text-sm animate-pulse\">" +
           h(status) + "...</div>"
  end
  html
end
