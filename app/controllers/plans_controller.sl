# Plans — list every plan from the solidb `plans` collection.
# Done plans with a body are candidates for conversion into tasks;
# all plans are listed so the user can review, refine, or discard stale ones.
# Supports ?q= (fulltext search), ?page=, ?per_page= for pagination.

fn index(req)
    let _email = session_get("user_email") ?? ""
    let _user = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
    let merged = req["params"] ?? req["query"] ?? {}
    let q = (merged["q"] ?? "").trim()
    let page = (merged["page"] ?? "1").to_i() rescue 1
    let per_page = (merged["per_page"] ?? "25").to_i() rescue 25
    if page < 1 then page = 1 end
    if per_page < 1 then per_page = 25 end

    let all = Plan.all().sort_by(fn(p) p.plan_id).reverse()
    let filtered
    let total_count
    if q == ""
      filtered = all
      total_count = all.length
    else
      let filtered_arr = []
      for p in all
        let prompt = p.prompt ?? ""
        let body_text = p.body ?? ""
        if prompt.contains(q) or body_text.contains(q)
          filtered_arr.push(p)
        end
      end
      filtered = filtered_arr
      total_count = filtered_arr.length
    end
    let offset = (page - 1) * per_page
    let plans = []
    let end_at = offset + per_page
    let i = offset
    while i < total_count and i < end_at
      plans.push(filtered[i])
      i = i + 1
    end
    let total_pages = (total_count + per_page - 1) / per_page
    let prev_page = page - 1
    let next_page = page + 1

    render("plans/index", {
        "current_user": _user,
        "title": "Plans",
        "plans": plans,
        "total_count": total_count,
        "total_pages": total_pages,
        "page": page,
        "per_page": per_page,
        "q": q,
        "prev_page": prev_page,
        "next_page": next_page,
        "linked_tasks": _linked_tasks_for(plans),
        "theme": Setting.current_theme(),
        "theme_css_vars": Setting.current_theme_css_vars(),
        "theme_class": Setting.current_theme_class()
    })
end

# Build a `{ plan_id -> Task }` lookup for plans that carry a task_slug.
# One `Task.where` call per distinct project (matched by slug locally),
# so the controller's task load is O(projects) instead of O(plans) and
# the view never has to issue its own `Task.find_by`.
fn _linked_tasks_for(plans)
    let projects = []
    let seen = {}
    for plan in plans
        let slug = (plan.task_slug ?? "").trim()
        let project = (plan.project ?? "").trim()
        if slug != "" and project != "" and seen[project] != true
            seen[project] = true
            projects.push(project)
        end
    end
    let by_key = {}
    for project in projects
        for task in Task.where({ "project": project }).all()
            by_key[project + "--" + task.slug] = task
        end
    end
    let out = {}
    for plan in plans
        let slug = (plan.task_slug ?? "").trim()
        let project = (plan.project ?? "").trim()
        if slug != "" and project != ""
            let task = by_key[project + "--" + slug]
            if task != nil
                out[plan.plan_id] = task
            end
        end
    end
    out
end