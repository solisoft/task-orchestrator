# Routes

# ── Authentication (unscoped) ────────

get("/login", "auth#login_form")
post("/login", "auth#login")
get("/logout", "auth#logout")

# ── Root & Utility ──────────────────

get("/", "home#index")
get("/plans", "plans#index")
get("/health", "home#health")
get("/debug", "debug#show")
get("/docs", "docs#index")

# ── Settings ─────────────────────────

get("/settings", "settings#show")
post("/settings", "settings#update")

# ── Projects ─────────────────────────

get("/projects/:name", "projects#show")

# ── Tasks ────────────────────────────

get("/projects/:name/tasks/new", "tasks#new")
# create must precede the static-segment plan route (Soli pruning)
post("/projects/:name/tasks", "tasks#create")
get("/projects/:name/tasks/:slug", "tasks#show")
post("/projects/:name/tasks/:slug/save", "tasks#save")
post("/projects/:name/tasks/:slug/queue", "tasks#queue")
post("/projects/:name/tasks/:slug/unqueue", "tasks#unqueue")
post("/projects/:name/tasks/:slug/merge", "tasks#merge_branch")
post("/projects/:name/tasks/:slug/checkout", "tasks#checkout_branch")
post("/projects/:name/tasks/:slug/mark-done", "tasks#mark_done")
post("/projects/:name/tasks/:slug/commit-push", "tasks#commit_push")
post("/projects/:name/tasks/:slug/archive", "tasks#archive")
post("/projects/:name/tasks/:slug/unarchive", "tasks#unarchive")

# ── Plans (per-project) ──────────────

post("/projects/:name/tasks/plan", "tasks#plan")
get("/projects/:name/tasks/plan-log/:plan_id", "tasks#plan_log")
post("/projects/:name/tasks/plan-answer/:plan_id", "tasks#plan_answer")
post("/projects/:name/tasks/plan-refine/:plan_id", "tasks#plan_refine")
post("/projects/:name/tasks/plan-retry/:plan_id",  "tasks#plan_retry")

# ── Runs ─────────────────────────────

get("/projects/:name/tasks/:slug/run", "runs#show")
get("/projects/:name/tasks/:slug/run/log", "runs#log")
post("/projects/:name/tasks/:slug/run/resume", "runs#resume")

# ── Push notifications ───────────────

post("/push_subscriptions", "push_subscriptions#create")
post("/push_subscriptions/delete", "push_subscriptions#destroy")
get("/push/vapid-public-key", "push_subscriptions#vapid_public_key")

# ── Auth-gated routes ─────────────────

middleware("authenticate", -> {

  # ── Features ─────────────────────────

  resources("features")
  post("/features/:id/generate_tasks", "features#generate_tasks")
  get("/features/:id/generate_tasks_log/:plan_id", "features#generate_tasks_log")

  # ── Comments (nested under features) ─

  post("/features/:id/comments", "comments#create")

})
