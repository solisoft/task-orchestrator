# Versions controller — CRUD for Shape Up cycles nested under a project.
class VersionsController < ApplicationController
  title: Any
  project: Any
  versions: Any
  version: Any
  features: Any

  def index(req)
    project_name = req["params"]["name"]
    project = Project.find_project(project_name)
    if project.nil?
      return {
        "status": 404,
        "body": "Unknown project: " + project_name
      }
    end

    @title = project_name + " — Versions"
    @project = project
    @versions = Version.for_project(project_name)
    render("versions/index")
  end

  def show(req)
    version = this._find_version(req)
    if version.nil?
      return {"status": 404, "body": "Version not found"}
    end

    @title = version.name
    @version = version
    @project = Project.find_project(version.project)
    @features = Feature.for_version(version._key)
    render("versions/show")
  end

  def new(req)
    project_name = req["params"]["name"]
    project = Project.find_project(project_name)
    if project.nil?
      return {
        "status": 404,
        "body": "Unknown project: " + project_name
      }
    end

    @title = "New Version"
    @version = nil
    @project = project
    render("versions/new")
  end

  def create(req)
    project_name = req["params"]["name"]
    project = Project.find_project(project_name)
    if project.nil?
      return {
        "status": 404,
        "body": "Unknown project: " + project_name
      }
    end

    form = req["all"] ?? {}
    name = (form["name"] ?? "").trim()
    status = (form["status"] ?? "").trim()
    if name == "" || status == ""
      return {"status": 422, "body": "Name and status are required"}
    end

    version = Version.create(this._permit_params(form, project_name))
    if version._errors
      return {"status": 422, "body": "Invalid version data"}
    end

    redirect("/projects/" + project_name + "?tab=roadmap")
  end

  def edit(req)
    version = this._find_version(req)
    if version.nil?
      return {"status": 404, "body": "Version not found"}
    end

    @title = "Edit — " + version.name
    @version = version
    @project = Project.find_project(version.project)
    render("versions/edit")
  end

  def update(req)
    version = this._find_version(req)
    if version.nil?
      return {"status": 404, "body": "Version not found"}
    end

    form = req["all"] ?? {}
    new_name = (form["name"] ?? "").trim()
    new_status = (form["status"] ?? "").trim()
    if new_name == ""
      return {"status": 422, "body": "Name is required"}
    end

    if new_status == ""
      return {"status": 422, "body": "Status is required"}
    end

    version.name = new_name
    version.code_name = (form["code_name"] ?? version.code_name ?? "").trim()
    version.due_date = (form["due_date"] ?? version.due_date ?? "").trim()
    version.status = new_status
    version.description = (form["description"] ?? version.description ?? "").trim()
    version.save()
    if version._errors
      return {"status": 422, "body": "Invalid version data"}
    end

    redirect("/projects/" + version.project + "?tab=roadmap")
  end

  def destroy(req)
    version = this._find_version(req)
    if version.nil?
      return {"status": 404, "body": "Version not found"}
    end

    project_name = version.project
    version.delete()
    redirect("/projects/" + project_name + "?tab=roadmap")
  end

  def _find_version(req)
    id = req["params"]["id"]
    Version.find_by("_key", id)
  end

  def _permit_params(form, project_name)
    {
      "name": (form["name"] ?? "").trim(),
      "code_name": (form["code_name"] ?? "").trim(),
      "due_date": (form["due_date"] ?? "").trim(),
      "status": (form["status"] ?? "planned").trim(),
      "description": (form["description"] ?? "").trim(),
      "project": project_name
    }
  end
end
