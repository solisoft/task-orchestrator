# Plans — list every plan under run_state_root()/_plans/. Done plans with
# a body are candidates for conversion into tasks; all plans are listed
# so the user can review, refine, or discard stale ones.

fn index(req)
  let plans_dir = run_state_root() + "/_plans"
  if not Trusted.is_dir(plans_dir)
    return render("plans/index", {
      "title": "Plans",
      "plans": []
    })
  end
  let dirs = _list_dirs(plans_dir)
  let plans = []
  for dir in dirs
    let segs = dir.split("/")
    let plan_id = segs[segs.length - 1]
    let state = _read_plan_state(plan_id)
    plans.push({
      "id":           plan_id,
      "status":       state["status"],
      "zombie":       state["zombie"],
      "body":         state["body"],
      "model":        state["model"],
      "prompt":       state["prompt"],
      "prompt_emoji": _plan_emoji(state["prompt"]),
      "log":          state["log"],
      "status_log":   state["status_log"],
      "project_path": state["project_path"]
    })
  end
  plans = plans.sort_by(fn(p) p["id"]).reverse()
  render("plans/index", {
    "title": "Plans",
    "plans": plans
  })
end

fn _read_plan_state(plan_id)
  let dir = run_state_root() + "/_plans/" + plan_id
  let status_json = _read_status_journal(dir + "/status")
  let status = status_json["last"]
  let status_log = status_json["lines"]

  let zombie = false
  if not _is_terminal_status(status)
    let age = _plan_status_age_seconds(dir + "/status")
    if age != nil and age > 600
      status = "zombie (stale after " + str(age / 60) + "m)"
      zombie = true
    end
  end

  let body = ""
  if status == "done"
    body = Trusted.read(dir + "/body") rescue ""
  end

  let model  = (Trusted.read(dir + "/model") rescue "").trim()
  let prompt = (Trusted.read(dir + "/prompt") rescue "")
  let log    = _plan_log_tail(dir + "/log", 16384)
  let project_path = (Trusted.read(dir + "/project_path") rescue "").trim()

  { "status":       status,
    "zombie":       zombie,
    "body":         body,
    "model":        model == "" ? "claude-sonnet-4-6" : model,
    "prompt":       prompt,
    "log":          log,
    "status_log":   status_log,
    "project_path": project_path }
end

fn _read_status_journal(path)
  let txt = (Trusted.read(path) rescue "").trim()
  let lines = []
  let last = "starting"
  if txt != ""
    for line in txt.split("\n")
      let trimmed = line.trim()
      if trimmed != ""
        let parts = trimmed.split("\t")
        if parts.length >= 2
          let ts = parts[0]
          let token = parts[parts.length - 1]
          lines.push({ "at": ts, "status": token })
          last = token
        end
      end
    end
  end
  { "last": last, "lines": lines }
end

fn _is_terminal_status(token)
  token == "done" or token.starts_with("failed") or token.starts_with("zombie")
end

fn _plan_status_age_seconds(path)
  if not Trusted.exists(path)
    return nil
  end
  let res = System.run_sync(["stat", "-c", "%Y", path])
  if res["exit_code"] != 0
    return nil
  end
  let mtime = (res["stdout"] ?? "").trim().to_int() rescue nil
  if mtime == nil
    return nil
  end
  DateTime.now().to_unix() - mtime
end

fn _plan_log_tail(path, max_bytes)
  if not Trusted.exists(path)
    return ""
  end
  let body = Trusted.read(path) rescue ""
  if body == ""
    return ""
  end
  if body.length <= max_bytes
    return body
  end
  body.substring(body.length - max_bytes, body.length)
end

fn _list_dirs(dir)
  let result = System.run_sync(["ls", "-1", dir])
  if result["exit_code"] != 0
    return []
  end
  let entries = []
  for line in result["stdout"].split("\n")
    if line != ""
      entries.push(dir + "/" + line)
    end
  end
  entries
end

# 10-char preview for the prompt column — strip leading # or whitespace.
fn _plan_emoji(prompt)
  let s = prompt.strip()
  if s == ""
    return ""
  end
  let n = 12
  if s.length() < n
    n = s.length()
  end
  s.substring(0, n).gsub("\n", " ")
end
