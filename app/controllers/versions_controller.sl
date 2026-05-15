# Versions controller — CRUD for Shape Up cycles nested under a project.

fn index(req)
  let project_name = req["params"]["name"]
  let project = find_project(project_name)
  if project == nil
    return { "status": 404, "body": "Unknown project: " + project_name }
  end
  let versions = Version.for_project(project_name)
  render("versions/index", {
    "title":     project_name + " — Versions",
    "project":   project,
    "versions":  versions,
    "theme":            Setting.current_theme(),
    "theme_css_vars":   Setting.current_theme_css_vars(),
    "theme_class":      Setting.current_theme_class()
  })
end

fn show(req)
  let version = _find_version(req)
  if version == nil
    return { "status": 404, "body": "Version not found" }
  end
  let project = find_project(version.project)
  let features = Feature.for_version(version._key)
  render("versions/show", {
    "title":    version.name,
    "version":  version,
    "project":  project,
    "features": features,
    "theme":          Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class":    Setting.current_theme_class()
  })
end

fn new(req)
  let project_name = req["params"]["name"]
  let project = find_project(project_name)
  if project == nil
    return { "status": 404, "body": "Unknown project: " + project_name }
  end
  render("versions/new", {
    "title":    "New Version",
    "version":  nil,
    "project":  project,
    "theme":          Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class":    Setting.current_theme_class()
  })
end

fn create(req)
  let project_name = req["params"]["name"]
  let project = find_project(project_name)
  if project == nil
    return { "status": 404, "body": "Unknown project: " + project_name }
  end
  let form = req["all"] ?? {}
  let name   = (form["name"]   ?? "").trim()
  let status = (form["status"] ?? "").trim()
  if name == "" or status == ""
    return { "status": 422, "body": "Name and status are required" }
  end
  let version = Version.create(_permit_params(form, project_name))
  if version._errors
    return { "status": 422, "body": "Invalid version data" }
  end
  redirect("/projects/" + project_name + "?tab=roadmap")
end

fn edit(req)
  let version = _find_version(req)
  if version == nil
    return { "status": 404, "body": "Version not found" }
  end
  let project = find_project(version.project)
  render("versions/edit", {
    "title":   "Edit — " + version.name,
    "version": version,
    "project": project,
    "theme":          Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class":    Setting.current_theme_class()
  })
end

fn update(req)
  let version = _find_version(req)
  if version == nil
    return { "status": 404, "body": "Version not found" }
  end
  let form = req["all"] ?? {}
  let new_name   = (form["name"]   ?? "").trim()
  let new_status = (form["status"] ?? "").trim()
  if new_name == ""
    return { "status": 422, "body": "Name is required" }
  end
  if new_status == ""
    return { "status": 422, "body": "Status is required" }
  end
  version.name        = new_name
  version.code_name   = (form["code_name"]   ?? version.code_name   ?? "").trim()
  version.due_date    = (form["due_date"]     ?? version.due_date    ?? "").trim()
  version.status      = new_status
  version.description = (form["description"]  ?? version.description ?? "").trim()
  version.save()
  if version._errors
    return { "status": 422, "body": "Invalid version data" }
  end
  redirect("/projects/" + version.project + "?tab=roadmap")
end

fn destroy(req)
  let version = _find_version(req)
  if version == nil
    return { "status": 404, "body": "Version not found" }
  end
  let project_name = version.project
  version.delete()
  redirect("/projects/" + project_name + "?tab=roadmap")
end

fn _find_version(req)
  let id = req["params"]["id"]
  Version.find_by("_key", id)
end

fn _permit_params(form, project_name)
  {
    "name":        (form["name"]        ?? "").trim(),
    "code_name":   (form["code_name"]   ?? "").trim(),
    "due_date":    (form["due_date"]    ?? "").trim(),
    "status":      (form["status"]      ?? "planned").trim(),
    "description": (form["description"] ?? "").trim(),
    "project":     project_name
  }
end
