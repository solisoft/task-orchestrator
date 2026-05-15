# VersionsController spec — CRUD for Shape Up cycles nested under a project.

# Derive the test server's origin from a probe response's url field.
# Needed to satisfy the CSRF middleware's Origin check on POST requests.
def _origin_for_worker()
  let probe = get("/login")
  let url = probe["url"] ?? ""
  let prefix = "http://"
  if not url.starts_with(prefix)
    return url
  end
  let rest = url.substring(prefix.length(), url.length())
  let slash = rest.index_of("/")
  if slash > 0
    return prefix + rest.substring(0, slash)
  end
  return url
end

# Setup helper: ensure a project directory exists on disk so find_project() works.
def _ensure_project(name)
  let root = getenv("TASK_ORCH_ROOT") ?? "/tmp/task-orch-spec"
  System.run_sync(["mkdir", "-p", root + "/" + name + "/tasks/todo"])
  root + "/" + name
end

def _make_version(project_name, name, status)
  Version.create({
    "project": project_name,
    "name":    name,
    "status":  status
  })
end

describe("Version model", fn()
  before_each(fn()
    assert_test_db()
    Version.delete_all()
  end)

  test("validates presence of name", fn()
    let v = Version.create({ "project": "proj", "status": "planned" })
    assert(v._errors != nil)
  end)

  test("validates presence of status", fn()
    let v = Version.create({ "project": "proj", "name": "v1" })
    assert(v._errors != nil)
  end)

  test("validates presence of project", fn()
    let v = Version.create({ "name": "v1", "status": "planned" })
    assert(v._errors != nil)
  end)

  test("validates status format", fn()
    let v = Version.create({ "project": "proj", "name": "v1", "status": "invalid" })
    assert(v._errors != nil)
  end)

  test("creates with valid data", fn()
    let v = Version.create({ "project": "proj", "name": "v1.0", "status": "planned" })
    assert(v._errors == nil)
    assert_eq(v.name, "v1.0")
    assert_eq(v.status, "planned")
    assert_eq(v.project, "proj")
  end)

  test("statuses returns the three lifecycle values", fn()
    let s = Version.statuses()
    assert_eq(s.length(), 3)
    assert_eq(s[0], "planned")
    assert_eq(s[1], "active")
    assert_eq(s[2], "shipped")
  end)

  test("for_project returns versions for a given project", fn()
    Version.create({ "project": "proj-a", "name": "v1", "status": "planned" })
    Version.create({ "project": "proj-a", "name": "v2", "status": "active" })
    Version.create({ "project": "proj-b", "name": "v1", "status": "planned" })
    let va = Version.for_project("proj-a")
    assert_eq(va.length(), 2)
  end)

  test("for_project returns empty for unknown project", fn()
    assert_eq(Version.for_project("no-such-project").length(), 0)
  end)

  test("for_project sorts active first, then planned, then shipped", fn()
    Version.create({ "project": "sort-proj", "name": "shipped-one", "status": "shipped" })
    Version.create({ "project": "sort-proj", "name": "planned-one", "status": "planned" })
    Version.create({ "project": "sort-proj", "name": "active-one",  "status": "active"  })
    let vs = Version.for_project("sort-proj")
    assert_eq(vs[0].status, "active")
    assert_eq(vs[1].status, "planned")
    assert_eq(vs[2].status, "shipped")
  end)
end)

describe("Feature.for_version", fn()
  before_each(fn()
    assert_test_db()
    Feature.delete_all()
    Version.delete_all()
  end)

  test("returns features assigned to a version", fn()
    let v = Version.create({ "project": "p", "name": "v1", "status": "planned" })
    Feature.create({ "_key": "p--f1", "project": "p", "slug": "f1", "title": "F1", "status": "draft", "version_id": v._key })
    Feature.create({ "_key": "p--f2", "project": "p", "slug": "f2", "title": "F2", "status": "draft", "version_id": v._key })
    Feature.create({ "_key": "p--f3", "project": "p", "slug": "f3", "title": "F3", "status": "draft" })
    let feats = Feature.for_version(v._key)
    assert_eq(feats.length(), 2)
  end)

  test("returns empty for nil version_id", fn()
    assert_eq(Feature.for_version(nil).length(), 0)
  end)

  test("returns empty for empty version_id", fn()
    assert_eq(Feature.for_version("").length(), 0)
  end)

  test("existing features without version_id continue to work", fn()
    let f = Feature.create({ "_key": "p--noversion", "project": "p", "slug": "noversion",
                             "title": "No version", "status": "draft" })
    assert(f._errors == nil)
    assert_null(f.version_id)
  end)
end)

describe("VersionsController GET routes", fn()
  before_each(fn()
    assert_test_db()
    Version.delete_all()
    Setting.delete_all()
    _ensure_project("versions-get-proj")
    User.delete_all()
    User.register("get-ver@test.com", "password", "Test")
    login("get-ver@test.com", "password")
  end)

  test("GET /projects/:name/versions returns 200", fn()
    let resp = get("/projects/versions-get-proj/versions")
    assert_eq(res_status(resp), 200)
  end)

  test("GET /projects/:name/versions returns 404 for unknown project", fn()
    let resp = get("/projects/nonexistent_xyz_ver/versions")
    assert_eq(res_status(resp), 404)
  end)

  test("GET /projects/:name/versions/new returns 200", fn()
    let resp = get("/projects/versions-get-proj/versions/new")
    assert_eq(res_status(resp), 200)
  end)

  test("GET /projects/:name/versions/new returns 404 for unknown project", fn()
    let resp = get("/projects/nonexistent_xyz_ver/versions/new")
    assert_eq(res_status(resp), 404)
  end)

  test("GET /projects/:name/versions/:id returns 200 for existing version", fn()
    let v = _make_version("versions-get-proj", "v1.0", "planned")
    let resp = get("/projects/versions-get-proj/versions/" + v._key)
    assert_eq(res_status(resp), 200)
  end)

  test("GET /projects/:name/versions/:id returns 404 for missing version", fn()
    let resp = get("/projects/versions-get-proj/versions/no-such-version-key")
    assert_eq(res_status(resp), 404)
  end)

  test("GET /projects/:name/versions/:id/edit returns 200", fn()
    let v = _make_version("versions-get-proj", "v2.0-edit", "planned")
    let resp = get("/projects/versions-get-proj/versions/" + v._key + "/edit")
    assert_eq(res_status(resp), 200)
  end)

  test("GET /projects/:name/versions/:id/edit returns 404 for missing version", fn()
    let resp = get("/projects/versions-get-proj/versions/no-such-key/edit")
    assert_eq(res_status(resp), 404)
  end)
end)

describe("VersionsController CRUD", fn()
  before_each(fn()
    assert_test_db()
    Version.delete_all()
    Setting.delete_all()
    User.delete_all()
    _ensure_project("versions-crud-proj")
    User.register("crud-ver@test.com", "password", "CRUD")
    login("crud-ver@test.com", "password")
  end)

  test("POST /projects/:name/versions creates a version and redirects", fn()
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions", {
      "name": "v1.0", "status": "planned"
    }, { "headers": { "Origin": origin } })
    assert_eq(res_status(resp), 302)
    let vs = Version.for_project("versions-crud-proj")
    assert_eq(vs.length(), 1)
    assert_eq(vs[0].name, "v1.0")
  end)

  test("POST /projects/:name/versions returns 422 on blank name", fn()
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions", {
      "name": "", "status": "planned"
    }, { "headers": { "Origin": origin } })
    assert_eq(res_status(resp), 422)
    assert_eq(Version.for_project("versions-crud-proj").length(), 0)
  end)

  test("POST /projects/:name/versions returns 404 for unknown project", fn()
    let origin = _origin_for_worker()
    let resp = post("/projects/nonexistent_xyz_ver/versions", {
      "name": "v1", "status": "planned"
    }, { "headers": { "Origin": origin } })
    assert_eq(res_status(resp), 404)
  end)

  test("POST /projects/:name/versions/:id/update updates name and status", fn()
    let v = _make_version("versions-crud-proj", "original-name", "planned")
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions/" + v._key + "/update", {
      "name": "updated-name", "status": "active"
    }, { "headers": { "Origin": origin } })
    assert_eq(res_status(resp), 302)
    let reloaded = Version.find_by("_key", v._key)
    assert_not_null(reloaded)
    assert_eq(reloaded.name, "updated-name")
    assert_eq(reloaded.status, "active")
  end)

  test("POST /projects/:name/versions/:id/update returns 422 on blank name", fn()
    let v = _make_version("versions-crud-proj", "valid-ver", "planned")
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions/" + v._key + "/update", {
      "name": "", "status": "planned"
    }, { "headers": { "Origin": origin } })
    assert_eq(res_status(resp), 422)
    let unchanged = Version.find_by("_key", v._key)
    assert_eq(unchanged.name, "valid-ver")
  end)

  test("POST /projects/:name/versions/:id/update returns 404 for missing version", fn()
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions/no-such-key/update", {
      "name": "x", "status": "planned"
    }, { "headers": { "Origin": origin } })
    assert_eq(res_status(resp), 404)
  end)

  test("POST /projects/:name/versions/:id/destroy deletes the version", fn()
    let v = _make_version("versions-crud-proj", "to-delete", "planned")
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions/" + v._key + "/destroy", {}, {
      "headers": { "Origin": origin }
    })
    assert_eq(res_status(resp), 302)
    assert_null(Version.find_by("_key", v._key))
  end)

  test("POST /projects/:name/versions/:id/destroy returns 404 for missing version", fn()
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions/no-such-key/destroy", {}, {
      "headers": { "Origin": origin }
    })
    assert_eq(res_status(resp), 404)
  end)

  test("POST /projects/:name/versions returns 422 on model validation failure", fn()
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions", {
      "name": "v-bad", "status": "not-a-valid-status"
    }, { "headers": { "Origin": origin } })
    assert_eq(res_status(resp), 422)
    assert_eq(Version.for_project("versions-crud-proj").length(), 0)
  end)

  test("POST /projects/:name/versions/:id/update returns 422 on invalid status format", fn()
    let v = _make_version("versions-crud-proj", "format-test", "planned")
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions/" + v._key + "/update", {
      "name": "format-test", "status": "not-a-valid-status"
    }, { "headers": { "Origin": origin } })
    assert_eq(res_status(resp), 422)
    let unchanged = Version.find_by("_key", v._key)
    assert_eq(unchanged.status, "planned")
  end)

  test("POST /projects/:name/versions creates version with all optional fields", fn()
    let origin = _origin_for_worker()
    let resp = post("/projects/versions-crud-proj/versions", {
      "name":        "Full Cycle",
      "code_name":   "Nighthawk",
      "status":      "active",
      "due_date":    "2026-09-01",
      "description": "Our biggest release yet"
    }, { "headers": { "Origin": origin } })
    assert_eq(res_status(resp), 302)
    let vs = Version.for_project("versions-crud-proj")
    assert_eq(vs.length(), 1)
    assert_eq(vs[0].code_name,   "Nighthawk")
    assert_eq(vs[0].due_date,    "2026-09-01")
    assert_eq(vs[0].description, "Our biggest release yet")
  end)
end)

describe("ProjectsController hub tabs with versions", fn()
  before_each(fn()
    assert_test_db()
    Version.delete_all()
    Task.delete_all()
    Feature.delete_all()
    Setting.delete_all()
    _ensure_project("hub-tab-proj")
    as_guest()
  end)

  test("GET /projects/:name?tab=roadmap returns 200 and renders roadmap", fn()
    let resp = get("/projects/hub-tab-proj?tab=roadmap")
    assert_eq(res_status(resp), 200)
    assert_contains(res_body(resp), "Roadmap")
  end)

  test("GET /projects/:name?tab=overview returns 200 and renders overview", fn()
    let resp = get("/projects/hub-tab-proj?tab=overview")
    assert_eq(res_status(resp), 200)
    assert_contains(res_body(resp), "Overview")
  end)

  test("GET /projects/:name?tab=board returns 200 and shows board", fn()
    let resp = get("/projects/hub-tab-proj?tab=board")
    assert_eq(res_status(resp), 200)
  end)

  test("GET /projects/:name without tab defaults to board hub", fn()
    let resp = get("/projects/hub-tab-proj")
    assert_eq(res_status(resp), 200)
  end)

  test("roadmap renders version cards for existing versions", fn()
    User.delete_all()
    User.register("hub-v@test.com", "password", "Hub")
    login("hub-v@test.com", "password")
    Version.create({ "project": "hub-tab-proj", "name": "Sprint One", "status": "active" })
    let resp = get("/projects/hub-tab-proj?tab=roadmap")
    assert_eq(res_status(resp), 200)
    assert_contains(res_body(resp), "Sprint One")
  end)
end)
