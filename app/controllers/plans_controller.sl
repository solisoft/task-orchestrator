# Plans — list every plan from the solidb `plans` collection.
# Done plans with a body are candidates for conversion into tasks;
# all plans are listed so the user can review, refine, or discard stale ones.

fn index(req)
    let plans = Plan.all()
    plans = plans.sort_by(fn(p) p.plan_id).reverse()
    render("plans/index", {
        "title": "Plans",
        "plans": plans
    })
end