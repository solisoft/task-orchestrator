# TicketSource — per-project ticket import (GitLab / GitHub via glab / gh,
# Bonfire over its JSON API). The CLI and HTTP calls are replaced by the
# `_ticket_source_mock` / `_bonfire_mock` Setting seams, so these specs
# exercise config, rule filtering and task creation without a network.

fn _ts_reset
  assert_test_db()
  Setting.delete_all()
  Task.delete_all()
end

fn _ts_gitlab_rows
  JSON.stringify([
    {
      "iid": 742,
      "title": "Facture déjà payée",
      "description": "Le détail",
      "web_url": "https://code.example.net/g/edifice/-/issues/742",
      "labels": ["P1", "en-cours"]
    },
    {
      "iid": 743,
      "title": "Tiers payeur",
      "description": "",
      "web_url": "https://code.example.net/g/edifice/-/issues/743",
      "labels": ["P1"]
    }
  ])
end

fn _ts_bonfire_board
  [
    {
      "name": "Backlog",
      "cards": [
        {"id": "c1", "number": 12, "title": "Mine P1", "labels": "P1, api", "description": "d",
         "assignee_id": "u-me"},
        {"id": "c2", "number": 13, "title": "Someone else", "labels": "P1", "description": "",
         "assignee_id": "u-other"},
        {"id": "c3", "number": 14, "title": "Mine but blocked", "labels": "P1, blocked", "description": "",
         "assignee_id": "u-me"},
        {"id": "c4", "number": nil, "title": "Mine no number", "labels": "p1", "description": "", "assignee_id": "u-me"}
      ]
    },
    {
      "name": "Doing",
      "cards": [
        {"id": "c5", "number": 15, "title": "In progress", "labels": "P1", "description": "", "assignee_id": "u-me"}
      ]
    }
  ]
end

describe("TicketSource.parse_remote", fn() {
  test("reads an scp-style ssh remote", fn() {
    r = TicketSource.parse_remote("git@code.example.net:sinoia/edifice/edifice.git")
    assert_eq(r["host"], "code.example.net")
    assert_eq(r["path"], "sinoia/edifice/edifice")
  })

  test("reads an https remote with credentials", fn() {
    r = TicketSource.parse_remote("https://user@github.com/solisoft/lang")
    assert_eq(r["host"], "github.com")
    assert_eq(r["path"], "solisoft/lang")
  })

  test("drops the ssh port from an ssh:// remote", fn() {
    r = TicketSource.parse_remote("ssh://git@code.example.net:2222/g/repo.git")
    assert_eq(r["host"], "code.example.net")
    assert_eq(r["path"], "g/repo")
  })

  test("returns blanks for nil, empty or unparseable remotes", fn() {
    assert_eq(TicketSource.parse_remote(nil)["host"], "")
    assert_eq(TicketSource.parse_remote("")["path"], "")
    assert_eq(TicketSource.parse_remote("not a url")["host"], "")
    assert_eq(TicketSource.parse_remote("https://hostonly")["host"], "")
  })
})

describe("TicketSource.split_labels", fn() {
  test("trims, drops blanks and splits newlines", fn() {
    assert_eq(TicketSource.split_labels("P1, backend ,,\nen-cours"), ["P1", "backend", "en-cours"])
    assert_eq(TicketSource.split_labels(nil), [])
  })
})

describe("TicketSource.save_config / config_for", fn() {
  before_each(fn() { _ts_reset() })

  test("defaults when nothing is stored", fn() {
    c = TicketSource.config_for("p")
    assert_eq(c["provider"], "")
    assert_eq(c["column"], "Backlog")
    assert(c["assigned_to_me"])
  })

  test("persists cleaned values", fn() {
    res = TicketSource.save_config("p", {
      "ticket_provider": "GitLab",
      "ticket_host": "https://code.example.net/",
      "ticket_repo": "/g/repo.git",
      "ticket_labels": "P1, api",
      "ticket_exclude_labels": "en-cours",
      "ticket_column": ""
    })
    assert(res["ok"])
    c = TicketSource.config_for("p")
    assert_eq(c["provider"], "gitlab")
    assert_eq(c["host"], "code.example.net")
    assert_eq(c["repo"], "g/repo")
    assert_eq(c["labels"], "P1, api")
    assert_eq(c["exclude_labels"], "en-cours")
    assert_eq(c["column"], "Backlog")
    assert_not(c["assigned_to_me"])
  })

  test("refuses an unknown provider, a bad host or a bad repo", fn() {
    assert_not(TicketSource.save_config("p", {"ticket_provider": "jira"})["ok"])
    assert_not(TicketSource.save_config("p", {"ticket_host": "evil host; rm"})["ok"])
    assert_not(TicketSource.save_config("p", {"ticket_repo": "--upload-pack=x"})["ok"])
    assert_null(Setting.get(TicketSource.setting_key("p")))
  })

  test("Bonfire needs a project id", fn() {
    res = TicketSource.save_config("p", {"ticket_provider": "bonfire", "ticket_repo": ""})
    assert_not(res["ok"])
    assert_contains(res["error"], "project id")
  })
})

describe("TicketSource.resolve", fn() {
  before_each(fn() { _ts_reset() })

  test("derives a GitLab source from the origin remote", fn() {
    r = TicketSource.resolve(TicketSource.config_for("p"), "git@code.example.net:g/repo.git")
    assert(r["ready"])
    assert_eq(r["provider"], "gitlab")
    assert_eq(r["host"], "code.example.net")
    assert_eq(r["repo"], "g/repo")
  })

  test("picks GitHub for a github.com remote", fn() {
    r = TicketSource.resolve(TicketSource.config_for("p"), "git@github.com:o/r.git")
    assert_eq(r["provider"], "github")
  })

  test("explicit fields win over the remote", fn() {
    TicketSource.save_config("p", {"ticket_provider": "gitlab", "ticket_host": "gl.corp", "ticket_repo": "x/y"})
    r = TicketSource.resolve(TicketSource.config_for("p"), "git@github.com:o/r.git")
    assert_eq(r["provider"], "gitlab")
    assert_eq(r["host"], "gl.corp")
    assert_eq(r["repo"], "x/y")
  })

  test("is not ready without a remote or explicit repo", fn() {
    r = TicketSource.resolve(TicketSource.config_for("p"), nil)
    assert_not(r["ready"])
    assert_contains(r["reason"], "remote")
  })

  test("Bonfire is not ready without a token, then without a project id", fn() {
    r = TicketSource.resolve(TicketSource.config_for("p").merge({"provider": "bonfire"}), nil)
    assert_not(r["ready"])
    assert_contains(r["reason"], "token")

    Setting.set("bonfire_token", "bonfire_pat_x")
    r2 = TicketSource.resolve(TicketSource.config_for("p").merge({"provider": "bonfire"}), nil)
    assert_not(r2["ready"])
    assert_contains(r2["reason"], "project id")
  })

  test("Bonfire uses the global URL (trailing slash dropped) and token", fn() {
    Setting.set("bonfire_token", "bonfire_pat_x")
    Setting.set("bonfire_url", "https://bf.example.net/")
    r = TicketSource.resolve(TicketSource.config_for("p").merge({"provider": "bonfire", "repo": "pid1"}), nil)
    assert(r["ready"])
    assert_eq(r["host"], "https://bf.example.net")
    assert_eq(r["token"], "bonfire_pat_x")
  })
})

describe("TicketSource.command", fn() {
  test("builds a glab call with every rule as --flag=value", fn() {
    argv = TicketSource.command({
      "provider": "gitlab", "host": "code.example.net", "repo": "g/repo",
      "labels": "P1, api", "exclude_labels": "en-cours", "assigned_to_me": true
    })
    assert_eq(argv[0], "glab")
    assert(argv.includes?("--repo=https://code.example.net/g/repo"))
    assert(argv.includes?("--assignee=@me"))
    assert(argv.includes?("--label=P1,api"))
    assert(argv.includes?("--not-label=en-cours"))
    assert(argv.includes?("--output=json"))
  })

  test("leaves out empty rules", fn() {
    argv = TicketSource.command({
      "provider": "gitlab", "host": "h", "repo": "g/r",
      "labels": "", "exclude_labels": "", "assigned_to_me": false
    })
    assert_not(argv.includes?("--assignee=@me"))
    assert_eq(argv.filter { |a| a.starts_with("--label") || a.starts_with("--not-label") }.length, 0)
  })

  test("builds a gh call; exclusions become a search query", fn() {
    argv = TicketSource.command({
      "provider": "github", "host": "github.com", "repo": "o/r",
      "labels": "P1, api", "exclude_labels": "wip", "assigned_to_me": true
    })
    assert_eq(argv[0], "gh")
    assert(argv.includes?("--repo=o/r"))
    assert(argv.includes?("--label=P1"))
    assert(argv.includes?("--label=api"))
    assert(argv.includes?("--assignee=@me"))
    assert(argv.includes?("--search=-label:\"wip\""))
  })

  test("prefixes a GitHub Enterprise host", fn() {
    argv = TicketSource.command({
      "provider": "github", "host": "ghe.corp", "repo": "o/r",
      "labels": "", "exclude_labels": "", "assigned_to_me": false
    })
    assert(argv.includes?("--repo=ghe.corp/o/r"))
  })
})

describe("TicketSource.normalize", fn() {
  test("maps GitLab rows", fn() {
    out = TicketSource.normalize("gitlab", JSON.parse(_ts_gitlab_rows()))
    assert_eq(out.length, 2)
    assert_eq(out[0]["ref"], "#742")
    assert_eq(out[0]["url"], "https://code.example.net/g/edifice/-/issues/742")
    assert_eq(out[0]["labels"], ["P1", "en-cours"])
  })

  test("maps GitHub rows and label objects", fn() {
    out = TicketSource.normalize("github", [
      {"number": 7, "title": "T", "body": "B", "url": "https://github.com/o/r/issues/7", "labels": [{"name": "P1"}]}
    ])
    assert_eq(out[0]["ref"], "#7")
    assert_eq(out[0]["description"], "B")
    assert_eq(out[0]["labels"], ["P1"])
  })

  test("drops junk rows and non-arrays", fn() {
    assert_eq(TicketSource.normalize("gitlab", nil), [])
    assert_eq(TicketSource.normalize("gitlab", ["x", {"iid": 1, "title": "", "web_url": "u"}]), [])
  })
})

describe("TicketSource.fetch", fn() {
  before_each(fn() { _ts_reset() })

  test("returns the reason when the source is not ready", fn() {
    res = TicketSource.fetch({"ready": false, "reason": "nope"})
    assert_not(res["ok"])
    assert_eq(res["error"], "nope")
  })

  test("reports a CLI failure", fn() {
    Setting.set("_ticket_source_mock_error", "glab failed: 401")
    res = TicketSource.fetch({"ready": true, "provider": "gitlab"})
    assert_not(res["ok"])
    assert_contains(res["error"], "401")
  })

  test("reports unreadable CLI output", fn() {
    Setting.set("_ticket_source_mock", "not json")
    res = TicketSource.fetch({"ready": true, "provider": "gitlab"})
    assert_not(res["ok"])
    assert_contains(res["error"], "Unreadable")
  })
})

describe("TicketSource.import_tickets", fn() {
  before_each(fn() { _ts_reset() })

  test("creates todo tasks with source fields, labels and a readable body", fn() {
    Setting.set("_ticket_source_mock", _ts_gitlab_rows())
    res = TicketSource.import_tickets("edifice", "git@code.example.net:g/edifice.git", "me@x.test")
    assert(res["ok"])
    assert_eq(res["created"], 2)
    assert_eq(res["skipped"], 0)

    t = Task.where({"project": "edifice", "source_ref": "#742"}).all[0]
    assert_eq(t.status, "todo")
    assert_eq(t.source, "gitlab")
    assert_eq(t.author, "me@x.test")
    assert_eq(t.source_labels, ["P1", "en-cours"])
    assert(t.slug.starts_with("742-facture-deja-payee"))
    assert_contains(t.body_md, "> Imported from GitLab #742: https://code.example.net/g/edifice/-/issues/742")
    assert_contains(t.body_md, "> Labels: P1, en-cours")
    assert_contains(t.body_md, "Le détail")
  })

  test("a second import skips known tickets and refreshes their labels", fn() {
    Setting.set("_ticket_source_mock", _ts_gitlab_rows())
    TicketSource.import_tickets("edifice", "git@code.example.net:g/edifice.git", "")
    rows = JSON.parse(_ts_gitlab_rows())
    rows[0]["labels"] = ["P1", "review"]
    Setting.set("_ticket_source_mock", JSON.stringify(rows))
    res = TicketSource.import_tickets("edifice", "git@code.example.net:g/edifice.git", "")
    assert_eq(res["created"], 0)
    assert_eq(res["skipped"], 2)
    assert_eq(Task.where({"project": "edifice"}).count, 2)
    t = Task.where({"project": "edifice", "source_ref": "#742"}).all[0]
    assert_eq(t.source_labels, ["P1", "review"])
  })

  test("passes a fetch error through and creates nothing", fn() {
    res = TicketSource.import_tickets("edifice", nil, "")
    assert_not(res["ok"])
    assert_eq(Task.where({"project": "edifice"}).count, 0)
  })
})

describe("TicketSource Bonfire", fn() {
  before_each(fn() { _ts_reset() })

  test("bonfire_issues keeps my cards of the column that match the rules", fn() {
    resolved = {"column": "backlog", "labels": "p1", "exclude_labels": "Blocked", "assigned_to_me": true}
    out = TicketSource.bonfire_issues(_ts_bonfire_board(), resolved, "u-me", "https://bf/c/co/p/pid/cards?open=")
    assert_eq(out.map { |i| i["title"] }, ["Mine P1", "Mine no number"])
    assert_eq(out[0]["ref"], "#12")
    assert_eq(out[0]["url"], "https://bf/c/co/p/pid/cards?open=c1")
    assert_eq(out[0]["labels"], ["P1", "api"])
    assert_eq(out[1]["ref"], "c4")
  })

  test("bonfire_issues without assigned_to_me keeps everyone's cards", fn() {
    resolved = {"column": "Backlog", "labels": "", "exclude_labels": "", "assigned_to_me": false}
    out = TicketSource.bonfire_issues(_ts_bonfire_board(), resolved, "u-me", "x")
    assert_eq(out.length, 4)
    assert_eq(TicketSource.bonfire_issues(nil, resolved, "u-me", "x"), [])
  })

  test("imports through the API with card URLs built from the company", fn() {
    Setting.set("bonfire_token", "bonfire_pat_x")
    Setting.set("bonfire_url", "https://bf.example.net")
    Setting.set("_bonfire_mock", {
      "/api/v1/me": {"data": {"id": "u-me", "email": "me@x.test"}},
      "/api/v1/projects/pid1": {"data": {"id": "pid1", "company_id": "co9"}},
      "/api/v1/projects/pid1/cards": {"data": _ts_bonfire_board()}
    })
    TicketSource.save_config("site", {
      "ticket_provider": "bonfire", "ticket_repo": "pid1",
      "ticket_labels": "P1", "ticket_exclude_labels": "blocked", "ticket_assigned_to_me": "1"
    })
    res = TicketSource.import_tickets("site", nil, "")
    assert(res["ok"])
    assert_eq(res["created"], 2)
    t = Task.where({"project": "site", "source_ref": "#12"}).all[0]
    assert_eq(t.source, "bonfire")
    assert_eq(t.source_url, "https://bf.example.net/c/co9/p/pid1/cards?open=c1")
    assert_contains(t.body_md, "> Imported from Bonfire #12")
  })

  test("a rejected token is reported as such", fn() {
    Setting.set("_bonfire_mock", {"/api/v1/me": {"status": 401}})
    res = TicketSource._bonfire_get({"host": "https://bf", "token": "t"}, "/api/v1/me")
    assert_not(res["ok"])
    assert_contains(res["error"], "401")
  })

  test("other statuses and unknown paths are errors", fn() {
    Setting.set("_bonfire_mock", {"/api/v1/me": {"status": 500}})
    assert_contains(TicketSource._bonfire_get({"host": "h", "token": "t"}, "/api/v1/me")["error"], "500")
    assert_contains(TicketSource._bonfire_get({"host": "h", "token": "t"}, "/nope")["error"], "404")
  })

  test("stops at the first failing call", fn() {
    Setting.set("bonfire_token", "bonfire_pat_x")
    Setting.set("_bonfire_mock", {"/api/v1/me": {"data": {"id": "u-me"}}})
    resolved = TicketSource.resolve(TicketSource.config_for("site").merge({"provider": "bonfire", "repo": "pid1"}), nil)
    res = TicketSource.fetch(resolved)
    assert_not(res["ok"])
    assert_contains(res["error"], "/api/v1/projects/pid1")
  })
})

describe("TicketSource helpers", fn() {
  test("slug_base caps the length without a trailing dash", fn() {
    slug = TicketSource.slug_base({"ref": "#9", "title": "a very long title " * 10})
    assert(slug.length <= 60)
    assert_not(slug.ends_with("-"))
    assert(slug.starts_with("9-a-very-long-title"))
  })

  test("body_for omits empty labels and description", fn() {
    body = TicketSource.body_for("github", {"ref": "#1", "title": "T", "url": "u", "labels": [], "description": ""})
    assert_eq(body, "# T\n\n> Imported from GitHub #1: u\n")
  })

  test("provider_label", fn() {
    assert_eq(TicketSource.provider_label("gitlab"), "GitLab")
    assert_eq(TicketSource.provider_label("bonfire"), "Bonfire")
  })
})
