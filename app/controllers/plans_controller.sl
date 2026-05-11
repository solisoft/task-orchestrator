# Plans — list every plan from the solidb `plans` collection.
# Done plans with a body are candidates for conversion into tasks;
# all plans are listed so the user can review, refine, or discard stale ones.

fn index(req)
    let plans = Plan.all()
    plans = plans.sort_by(fn(p) p.plan_id).reverse()
    render("plans/index", {
        "title": "Plans",
        "plans": plans,
        "linked_tasks": _linked_tasks_for(plans)
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