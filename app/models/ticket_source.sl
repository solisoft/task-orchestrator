# TicketSource — per-project issue tracker the board imports tickets from.
#
# Each project picks a provider and the rules a ticket must meet:
#   - `labels`          every listed label is required (AND)
#   - `exclude_labels`  any listed label rules the ticket out
#   - `assigned_to_me`  only tickets assigned to the authenticated user
# Closed / done tickets are never imported.
#
# Providers:
#   - `gitlab` / `github` — host and repo default to the project's
#     `origin` remote (so a company GitLab such as `code.plugandwork.net`
#     works out of the box). Read through the provider's own CLI
#     (`glab issue list`, `gh issue list`), so authentication stays with
#     `glab auth login` / `gh auth login` — no token is stored here. The
#     CLI runs as an argv array (no shell) and every user-supplied value
#     is passed as `--flag=value`, so it can't be read as an extra flag.
#   - `bonfire` — cards of one Bonfire project (`repo` = its project id)
#     sitting in one card-table column (`column`, default "Backlog"),
#     read over Bonfire's JSON API with the global `bonfire_url` /
#     `bonfire_token` settings.
#
# Config lives in one Setting row per project: `ticket_source:<project>`.
class TicketSource
  static def providers()
    ["gitlab", "github", "bonfire"]
  end

  static def provider_label(provider)
    return "GitHub" if provider == "github"
    return "Bonfire" if provider == "bonfire"

    "GitLab"
  end

  static def default_bonfire_url()
    "https://bonfire.solisoft.net"
  end

  static def setting_key(project)
    "ticket_source:" + project
  end

  # Stored config merged over the defaults. Always returns every key.
  static def config_for(project)
    stored = Setting.get(TicketSource.setting_key(project)) rescue nil
    stored = {} if !stored.is_a?("hash")
    {
      "provider": stored["provider"] ?? "",
      "host": stored["host"] ?? "",
      "repo": stored["repo"] ?? "",
      "labels": stored["labels"] ?? "",
      "exclude_labels": stored["exclude_labels"] ?? "",
      "column": stored["column"] ?? "Backlog",
      "assigned_to_me": stored["assigned_to_me"] ?? true
    }
  end

  # Validate and persist the settings-modal fields. Returns
  # `{"ok": true}` or `{"ok": false, "error": <message>}`; nothing is
  # written on error. Empty provider/host/repo mean "derive from origin".
  static def save_config(project, form)
    provider = str(form["ticket_provider"] ?? "").trim.downcase
    host = TicketSource._clean_host(str(form["ticket_host"] ?? ""))
    repo = TicketSource._clean_repo(str(form["ticket_repo"] ?? ""))
    labels = TicketSource.split_labels(form["ticket_labels"])
    exclude = TicketSource.split_labels(form["ticket_exclude_labels"])
    column = str(form["ticket_column"] ?? "").replace("\n", " ").replace("\r", " ").trim
    column = "Backlog" if column == ""

    if provider != "" && !TicketSource.providers().includes?(provider)
      return {"ok": false, "error": "Unknown ticket provider: " + provider}
    end
    if host != "" && !Regex.matches("^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$", host)
      return {"ok": false, "error": "Invalid host: " + host}
    end
    if repo != "" && !Regex.matches("^[A-Za-z0-9_][A-Za-z0-9._/-]*$", repo)
      return {"ok": false, "error": "Invalid repository path: " + repo}
    end
    if provider == "bonfire" && repo == ""
      return {"ok": false, "error": "Bonfire needs the project id"}
    end

    Setting.set(TicketSource.setting_key(project), {
      "provider": provider,
      "host": host,
      "repo": repo,
      "labels": labels.join(", "),
      "exclude_labels": exclude.join(", "),
      "column": column,
      "assigned_to_me": form["ticket_assigned_to_me"].present?
    })
    {"ok": true}
  end

  # "P1, backend ,," → ["P1", "backend"]. Newlines are dropped so a
  # label can't smuggle a second line into the CLI's argument.
  static def split_labels(raw)
    str(raw ?? "").replace("\n", ",").replace("\r", ",").split(",").map { |l| l.trim }.filter { |l| l != "" }
  end

  # Config with every blank filled from the `origin` remote. Adds
  # `"ready"` (enough to run an import) and, when not ready, `"reason"`.
  static def resolve(config, remote_url)
    return TicketSource._resolve_bonfire(config) if config["provider"] == "bonfire"

    remote = TicketSource.parse_remote(remote_url)
    host = config["host"] != "" ? config["host"] : remote["host"]
    provider = config["provider"]
    provider = (host == "github.com" ? "github" : "gitlab") if provider == "" && host != ""
    repo = config["repo"] != "" ? config["repo"] : remote["path"]
    resolved = config.merge({"provider": provider, "host": host, "repo": repo, "ready": true})
    if host == "" || repo == ""
      resolved["ready"] = false
      resolved["reason"] = "No git remote to derive the repository from — set the host and repository."
    end
    resolved
  end

  # Bonfire reads the global URL + token; the project id is mandatory.
  static def _resolve_bonfire(config)
    url = TicketSource._strip_slashes(str(Setting.get_or("bonfire_url", "")).trim)
    url = TicketSource.default_bonfire_url() if url == ""
    token = str(Setting.get_or("bonfire_token", "")).trim
    resolved = config.merge({"host": url, "token": token, "ready": true})
    if token == ""
      resolved["ready"] = false
      resolved["reason"] = "No Bonfire token — add one in Settings."
    elsif config["repo"] == ""
      resolved["ready"] = false
      resolved["reason"] = "Set the Bonfire project id in the project settings."
    end
    resolved
  end

  # `git@host:group/repo.git` / `https://host/group/repo(.git)` →
  # `{"host", "path"}` (path keeps GitLab subgroups). Blank on failure.
  static def parse_remote(url)
    blank = {"host": "", "path": ""}
    return blank if url.nil? || url == ""

    s = url.trim
    host = ""
    rest = ""
    scheme_end = s.index_of("://")
    if scheme_end >= 0
      after = s.substring(scheme_end + 3, s.length)
      slash = after.index_of("/")
      return blank if slash < 0

      host = after.substring(0, slash)
      rest = after.substring(slash + 1, after.length)
      at = host.index_of("@")
      host = host.substring(at + 1, host.length) if at >= 0
      # ssh://git@host:2222/… — the port belongs to ssh, not to the web UI.
      colon = host.index_of(":")
      host = host.substring(0, colon) if colon >= 0 && s.starts_with("ssh://")
    else
      at = s.index_of("@")
      colon = s.index_of(":")
      return blank if colon < 0

      host = s.substring(at + 1, colon)
      rest = s.substring(colon + 1, s.length)
    end
    rest = rest.substring(0, rest.length - 4) if rest.ends_with(".git")
    rest = rest.substring(1, rest.length) if rest.starts_with("/")
    return blank if host == "" || rest == ""

    {"host": host, "path": rest}
  end

  # The CLI invocation (argv array) listing the open tickets that match
  # the rules, as JSON.
  static def command(resolved)
    labels = TicketSource.split_labels(resolved["labels"])
    exclude = TicketSource.split_labels(resolved["exclude_labels"])
    if resolved["provider"] == "github"
      repo = resolved["host"] == "github.com" ? resolved["repo"] : resolved["host"] + "/" + resolved["repo"]
      argv = [
        "gh", "issue", "list",
        "--repo=" + repo,
        "--state=open",
        "--limit=100",
        "--json=number,title,body,url,labels"
      ]
      argv.push("--assignee=@me") if resolved["assigned_to_me"]
      labels.each { |l| argv.push("--label=" + l) }
      if exclude.length > 0
        argv.push("--search=" + exclude.map { |l| "-label:\"" + l.replace("\"", "") + "\"" }.join(" "))
      end
      return argv
    end

    argv = [
      "glab", "issue", "list",
      "--repo=https://" + resolved["host"] + "/" + resolved["repo"],
      "--output=json",
      "--per-page=100"
    ]
    argv.push("--assignee=@me") if resolved["assigned_to_me"]
    argv.push("--label=" + labels.join(",")) if labels.length > 0
    argv.push("--not-label=" + exclude.join(",")) if exclude.length > 0
    argv
  end

  # CLI JSON → `[{"ref", "title", "description", "url", "labels"}]`.
  # Rows missing a URL or title are dropped.
  static def normalize(provider, rows)
    return [] if !rows.is_a?("array")

    out = []
    for row in rows
      next if !row.is_a?("hash")

      if provider == "github"
        out.push({
          "ref": "#" + str(row["number"]),
          "title": row["title"] ?? "",
          "description": row["body"] ?? "",
          "url": row["url"] ?? "",
          "labels": (row["labels"] ?? []).map { |l| l.is_a?("hash") ? (l["name"] ?? "") : str(l) }
        })
      else
        out.push({
          "ref": "#" + str(row["iid"]),
          "title": row["title"] ?? "",
          "description": row["description"] ?? "",
          "url": row["web_url"] ?? "",
          "labels": row["labels"] ?? []
        })
      end
    end
    out.filter { |i| i["url"] != "" && i["title"] != "" }
  end

  # Run the CLI and return `{"ok": true, "issues": [...]}` or
  # `{"ok": false, "error": ...}`.
  #
  # Test seam: a `_ticket_source_mock` Setting holds the CLI's stdout
  # (JSON string) and short-circuits the shell-out, same idea as
  # `_pr_merged_mock`; `_ticket_source_mock_error` simulates a failure.
  static def fetch(resolved)
    return {"ok": false, "error": resolved["reason"]} if !resolved["ready"]
    return TicketSource._fetch_bonfire(resolved) if resolved["provider"] == "bonfire"

    mock_error = Setting.get("_ticket_source_mock_error") rescue nil
    return {"ok": false, "error": mock_error} if mock_error.present?

    stdout = Setting.get("_ticket_source_mock") rescue nil
    if stdout.nil?
      argv = TicketSource.command(resolved)
      res = System.run_sync(["timeout", "60"] + argv)
      if res["exit_code"] != 0
        err = (res["stderr"] ?? "").trim
        err = "exit code " + str(res["exit_code"]) if err == ""
        return {"ok": false, "error": argv[0] + " failed: " + err}
      end
      stdout = res["stdout"] ?? ""
    end
    rows = JSON.parse(stdout) rescue nil
    return {"ok": false, "error": "Unreadable output from the " + resolved["provider"] + " CLI"} if !rows.is_a?("array")

    {"ok": true, "issues": TicketSource.normalize(resolved["provider"], rows)}
  end

  # Bonfire: who am I, which company owns the project (for card URLs),
  # then the project's columns with their cards — filtered here, since
  # the API has no server-side filters.
  static def _fetch_bonfire(resolved)
    pid = url_encode(resolved["repo"])
    me = TicketSource._bonfire_get(resolved, "/api/v1/me")
    return me if !me["ok"]

    project = TicketSource._bonfire_get(resolved, "/api/v1/projects/" + pid)
    return project if !project["ok"]

    board = TicketSource._bonfire_get(resolved, "/api/v1/projects/" + pid + "/cards")
    return board if !board["ok"]

    company = str(project["data"]["company_id"] ?? "")
    card_base = resolved["host"] + "/c/" + company + "/p/" + resolved["repo"] + "/cards?open="
    issues = TicketSource.bonfire_issues(board["data"], resolved, me["data"]["id"], card_base)
    {"ok": true, "issues": issues}
  end

  # Cards of `resolved["column"]` (case-insensitive) that match the
  # rules, normalised like the CLI providers' issues.
  static def bonfire_issues(columns, resolved, my_id, card_base)
    return [] if !columns.is_a?("array")

    wanted_column = resolved["column"].downcase
    required = TicketSource.split_labels(resolved["labels"]).map { |l| l.downcase }
    excluded = TicketSource.split_labels(resolved["exclude_labels"]).map { |l| l.downcase }
    out = []
    for column in columns
      next if str(column["name"] ?? "").trim.downcase != wanted_column

      for card in (column["cards"] ?? [])
        next if resolved["assigned_to_me"] && (card["assignee_id"] ?? "") != my_id

        labels = TicketSource.split_labels(card["labels"])
        have = labels.map { |l| l.downcase }
        next if required.any? { |l| !have.includes?(l) }
        next if excluded.any? { |l| have.includes?(l) }

        num = card["number"]
        out.push({
          "ref": num.nil? ? str(card["id"]) : "#" + str(num),
          "title": card["title"] ?? "",
          "description": card["description"] ?? "",
          "url": card_base + str(card["id"]),
          "labels": labels
        })
      end
    end
    out.filter { |i| i["title"] != "" }
  end

  # GET a Bonfire API path → `{"ok": true, "data": ...}` (the API wraps
  # payloads in `{"data": ...}`) or `{"ok": false, "error"}`.
  #
  # Test seam: a `_bonfire_mock` Setting maps a path to the payload it
  # returns (`{"status": 401}` for an error), skipping the network.
  static def _bonfire_get(resolved, path)
    mock = Setting.get("_bonfire_mock") rescue nil
    status = 0
    body = nil
    if mock.is_a?("hash")
      entry = mock[path] ?? {"status": 404}
      status = entry["status"] ?? 200
      body = entry
    else
      headers = {"Authorization": "Bearer " + resolved["token"], "Accept": "application/json"}
      res = nil
      try
        res = HTTP.request("GET", resolved["host"] + path, headers, nil)
      catch e
        return {"ok": false, "error": "Bonfire unreachable: " + str(e)}
      end
      status = res["status"]
      raw = res["body"]
      body = raw.is_a?("string") ? (JSON.parse(raw) rescue nil) : raw
    end
    return {"ok": false, "error": "Bonfire rejected the token (401) — check it in Settings."} if status == 401
    return {"ok": false, "error": "Bonfire " + path + " answered " + str(status)} if status != 200
    return {"ok": false, "error": "Unreadable answer from Bonfire " + path} if !body.is_a?("hash")

    {"ok": true, "data": body["data"]}
  end

  # Import every matching ticket as a `todo` task, skipping tickets whose
  # URL is already on a task of this project. Returns
  # `{"ok", "created", "skipped"}` or `{"ok": false, "error"}`.
  static def import_tickets(project, remote_url, author)
    resolved = TicketSource.resolve(TicketSource.config_for(project), remote_url)
    fetched = TicketSource.fetch(resolved)
    return fetched if !fetched["ok"]

    created = 0
    skipped = 0
    for issue in fetched["issues"]
      existing = Task.where({"project": project, "source_url": issue["url"]}).all
      if existing.length > 0
        # Already imported: only keep its labels in step with the tracker.
        Task.update(existing[0]._key, {"source_labels": issue["labels"]})
        skipped = skipped + 1
        next
      end

      slug = Task.unique_slug_for(project, TicketSource.slug_base(issue))
      task = Task.create({
        "project": project,
        "slug": slug,
        "title": issue["title"],
        "body_md": TicketSource.body_for(resolved["provider"], issue),
        "author": author ?? "",
        "status": "todo",
        "source": resolved["provider"],
        "source_ref": issue["ref"],
        "source_url": issue["url"],
        "source_labels": issue["labels"]
      }, {"key": Task.key_for(project, slug)})
      if task._errors
        skipped = skipped + 1
      else
        created = created + 1
      end
    end
    {"ok": true, "created": created, "skipped": skipped}
  end

  # "752-rfe-spirit-cas-12-…", capped so URLs stay readable.
  static def slug_base(issue)
    num = issue["ref"].replace("#", "")
    base = (num + "-" + issue["title"]).slugify
    base = base.substring(0, 60) if base.length > 60
    while base.ends_with("-")
      base = base.substring(0, base.length - 1)
    end
    base
  end

  static def body_for(provider, issue)
    label = TicketSource.provider_label(provider)
    lines = [
      "# " + issue["title"],
      "",
      "> Imported from " + label + " " + issue["ref"] + ": " + issue["url"]
    ]
    lines.push("> Labels: " + issue["labels"].join(", ")) if issue["labels"].length > 0
    desc = (issue["description"] ?? "").trim
    lines.push("") if desc != ""
    lines.push(desc) if desc != ""
    lines.join("\n") + "\n"
  end

  # "https://code.example.net/" → "code.example.net"
  static def _clean_host(raw)
    h = raw.trim
    scheme_end = h.index_of("://")
    h = h.substring(scheme_end + 3, h.length) if scheme_end >= 0
    TicketSource._strip_slashes(h)
  end

  static def _strip_slashes(s)
    out = s
    while out.ends_with("/")
      out = out.substring(0, out.length - 1)
    end
    out
  end

  # "/group/repo.git" → "group/repo"
  static def _clean_repo(raw)
    r = raw.trim
    r = r.substring(0, r.length - 4) if r.ends_with(".git")
    while r.starts_with("/")
      r = r.substring(1, r.length)
    end
    while r.ends_with("/")
      r = r.substring(0, r.length - 1)
    end
    r
  end
end
