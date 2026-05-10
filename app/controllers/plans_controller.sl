# Plans — list completed plan specs that haven't been converted to tasks yet.
# Scans the on-disk `_plans/` directory under run_state_root().

fn index(req)
  render("plans/index", {
    "title": "Plans",
    "plans": _list_plans()
  })
end

fn _list_plans()
  let plans_dir = run_state_root() + "/_plans"
  if not Trusted.is_dir(plans_dir)
    return []
  end
  let out = []
  for entry in list_dir(plans_dir)
    if not Trusted.is_dir(entry)
      next
    end
    let segs = entry.split("/")
    let plan_id = segs[segs.length - 1]
    let plan = _read_plan(plan_id) rescue nil
    if plan != nil and not plan["has_task"]
      out.push(plan)
    end
  end
  out.sort_by(fn(p) p["plan_id"])
end

fn _read_plan(plan_id)
  let dir = run_state_root() + "/_plans/" + plan_id
  let status_text = (Trusted.read(dir + "/status") rescue "").trim()
  if status_text == ""
    return nil
  end
  let lines = status_text.split("\n")
  let last_line = lines[lines.length - 1].trim()
  let parts = last_line.split("\t")
  let status = parts[parts.length - 1]
  if status != "done"
    return nil
  end
  let body = (Trusted.read(dir + "/body") rescue "").trim()
  if body == ""
    return nil
  end
  let title = _parse_title(body)
  if title == ""
    return nil
  end
  let project_path = (Trusted.read(dir + "/project_path") rescue "").trim()
  let project_name = ""
  let has_task = false
  if project_path != ""
    let segs = project_path.split("/")
    project_name = segs[segs.length - 1]
    let slug = title.slugify()
    let task = Task.find_by_slug(project_name, slug) rescue nil
    if task != nil
      has_task = true
    end
  end
  return {
    "plan_id":      plan_id,
    "title":        title,
    "has_task":     has_task,
    "project_name": project_name,
    "body":         body
  }
end

fn _parse_title(body)
  for line in body.split("\n")
    let s = line.trim()
    if s.starts_with("# ") and not s.starts_with("## ")
      return s.substring(2, s.length).trim()
    end
  end
  ""
end
