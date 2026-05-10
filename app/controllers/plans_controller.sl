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
      "id":      plan_id,
      "status":  state["status"],
      "body":    state["body"],
      "model":   state["model"],
      "prompt":  state["prompt"],
      "prompt_emoji": _plan_emoji(state["prompt"])
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
  let status = _read_last_status(dir + "/status")
  let body = ""
  if status == "done"
    body = Trusted.read(dir + "/body") rescue ""
  end
  let model  = (Trusted.read(dir + "/model") rescue "").trim()
  let prompt = (Trusted.read(dir + "/prompt") rescue "")
  { "status": status,
    "body":   body,
    "model":  model == "" ? "claude-sonnet-4-6" : model,
    "prompt": prompt }
end

fn _read_last_status(path)
  let txt = (Trusted.read(path) rescue "").trim()
  if txt == ""
    return "starting"
  end
  let lines = txt.split("\n")
  let last_line = lines[lines.length - 1].trim()
  let parts = last_line.split("\t")
  parts[parts.length - 1]
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
  s.substring(0, n).replace_all("\n", " ")
end
